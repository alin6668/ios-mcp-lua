#import "LuaManager.h"
#import "MCPServerInternal.h"
#import "HIDManager.h"
#import "ScreenManager.h"
#import "ClipboardManager.h"
#import "AppManager.h"
#import "AccessibilityManager.h"
#import "TextInputManager.h"
#import "FileSystemManager.h"
#import "LogManager.h"
#import "OCRManager.h"
#import "MCPProcessUtil.h"
#import "MCPLogger.h"

// Lua 5.4 C API
#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"

// ============================================================
// Forward declarations for Lua C functions
// ============================================================

static int ios_screenshot(lua_State *L);
static int ios_tap(lua_State *L);
static int ios_swipe(lua_State *L);
static int ios_long_press(lua_State *L);
static int ios_double_tap(lua_State *L);
static int ios_drag(lua_State *L);
static int ios_input_text(lua_State *L);
static int ios_type_text(lua_State *L);
static int ios_press_key(lua_State *L);
static int ios_press_home(lua_State *L);
static int ios_press_power(lua_State *L);
static int ios_press_volume_up(lua_State *L);
static int ios_press_volume_down(lua_State *L);
static int ios_wake_and_home(lua_State *L);
static int ios_toggle_mute(lua_State *L);
static int ios_launch_app(lua_State *L);
static int ios_kill_app(lua_State *L);
static int ios_list_apps(lua_State *L);
static int ios_list_running_apps(lua_State *L);
static int ios_get_frontmost_app(lua_State *L);
static int ios_get_app_info(lua_State *L);
static int ios_install_app(lua_State *L);
static int ios_uninstall_app(lua_State *L);
static int ios_get_ui_elements(lua_State *L);
static int ios_get_element_at_point(lua_State *L);
static int ios_find_element(lua_State *L);
static int ios_wait_for_element(lua_State *L);
static int ios_wait_for_disappear(lua_State *L);
static int ios_ocr_screen(lua_State *L);
static int ios_get_screen_info(lua_State *L);
static int ios_get_clipboard(lua_State *L);
static int ios_set_clipboard(lua_State *L);
static int ios_open_url(lua_State *L);
static int ios_get_device_info(lua_State *L);
static int ios_run_command(lua_State *L);
static int ios_get_brightness(lua_State *L);
static int ios_set_brightness(lua_State *L);
static int ios_get_volume(lua_State *L);
static int ios_set_volume(lua_State *L);
static int ios_read_file(lua_State *L);
static int ios_write_file(lua_State *L);
static int ios_list_dir(lua_State *L);
static int ios_get_syslog(lua_State *L);
static int ios_get_crash_logs(lua_State *L);
static int ios_read_crash_log(lua_State *L);
static int ios_sleep_ms(lua_State *L);
static int ios_log(lua_State *L);

// ============================================================
// Helper: convert ObjC objects → Lua stack
// ============================================================
static void push_objc_value(lua_State *L, id value) {
    if (!value || value == [NSNull null]) {
        lua_pushnil(L);
    } else if ([value isKindOfClass:[NSString class]]) {
        lua_pushstring(L, [(NSString *)value UTF8String]);
    } else if ([value isKindOfClass:[NSNumber class]]) {
        NSNumber *num = (NSNumber *)value;
        if (strcmp([num objCType], @encode(BOOL)) == 0) {
            lua_pushboolean(L, [num boolValue]);
        } else if (strcmp([num objCType], @encode(double)) == 0 ||
                   strcmp([num objCType], @encode(float)) == 0) {
            lua_pushnumber(L, [num doubleValue]);
        } else {
            lua_pushinteger(L, [num longLongValue]);
        }
    } else if ([value isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)value;
        lua_newtable(L);
        [dict enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
            push_objc_value(L, obj);
            if ([key isKindOfClass:[NSString class]]) {
                lua_setfield(L, -2, [(NSString *)key UTF8String]);
            } else {
                lua_pop(L, 1);
            }
        }];
    } else if ([value isKindOfClass:[NSArray class]]) {
        NSArray *arr = (NSArray *)value;
        lua_newtable(L);
        [arr enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
            push_objc_value(L, obj);
            lua_seti(L, -2, (lua_Integer)(idx + 1));
        }];
    } else if ([value isKindOfClass:[NSData class]]) {
        lua_pushlstring(L, [(NSData *)value bytes], [(NSData *)value length]);
    } else {
        lua_pushstring(L, [[value description] UTF8String]);
    }
}

// Convert a Lua value at stack index → ObjC id
static id to_objc_value(lua_State *L, int idx) {
    int type = lua_type(L, idx);
    switch (type) {
        case LUA_TNIL:
            return [NSNull null];
        case LUA_TBOOLEAN:
            return @(lua_toboolean(L, idx));
        case LUA_TNUMBER:
            if (lua_isinteger(L, idx))
                return @(lua_tointeger(L, idx));
            else
                return @(lua_tonumber(L, idx));
        case LUA_TSTRING: {
            size_t len;
            const char *s = lua_tolstring(L, idx, &len);
            return [[NSString alloc] initWithBytes:s length:len encoding:NSUTF8StringEncoding];
        }
        case LUA_TTABLE: {
            BOOL isArray = YES;
            lua_Integer maxIdx = 0;
            lua_pushnil(L);
            while (lua_next(L, idx < 0 ? idx - 1 : idx)) {
                if (lua_type(L, -2) == LUA_TNUMBER) {
                    lua_Integer k = lua_tointeger(L, -2);
                    if (k < 1) isArray = NO;
                    if (k > maxIdx) maxIdx = k;
                } else {
                    isArray = NO;
                }
                lua_pop(L, 1);
            }
            // Check gap-free array
            if (isArray && maxIdx > 0) {
                lua_pushnil(L);
                int count = 0;
                while (lua_next(L, idx < 0 ? idx - 1 : idx)) {
                    count++;
                    lua_pop(L, 1);
                }
                if (count != (int)maxIdx) isArray = NO;
            }

            if (isArray && maxIdx > 0) {
                NSMutableArray *arr = [NSMutableArray arrayWithCapacity:(NSUInteger)maxIdx];
                for (lua_Integer i = 1; i <= maxIdx; i++) {
                    lua_geti(L, idx, i);
                    [arr addObject:to_objc_value(L, -1)];
                    lua_pop(L, 1);
                }
                return arr;
            } else {
                NSMutableDictionary *dict = [NSMutableDictionary dictionary];
                lua_pushnil(L);
                while (lua_next(L, idx < 0 ? idx - 1 : idx)) {
                    id val = to_objc_value(L, -1);
                    id key = to_objc_value(L, -2);
                    if ([key isKindOfClass:[NSString class]]) {
                        dict[key] = val;
                    } else if ([key isKindOfClass:[NSNumber class]]) {
                        dict[[key stringValue]] = val;
                    }
                    lua_pop(L, 1);
                }
                return dict;
            }
        }
        default:
            return [NSNull null];
    }
}

// ============================================================
// Helper: call a block synchronously with semaphore
// ============================================================
static BOOL run_sync_bool(BOOL(^block)(void)) {
    return block();
}

static NSString *run_sync_string(NSString *(^block)(void)) {
    return block();
}

static NSDictionary *run_sync_dict(NSDictionary *(^block)(void)) {
    return block();
}

// ============================================================
// Helper: button press completion wrapper
// ============================================================
static BOOL press_button_sync(HIDButtonType button, double durationMs) {
    __block BOOL ok = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[IOSMCPHIDManager sharedInstance] pressButton:button
                                          duration:durationMs
                                        completion:^(BOOL success, NSString *error) {
        ok = success;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    return ok;
}

// ============================================================
// Helper: tap completion wrapper
// ============================================================
static BOOL tap_sync(CGFloat x, CGFloat y) {
    __block BOOL ok = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[IOSMCPHIDManager sharedInstance] tapAtPoint:CGPointMake(x, y)
                                       completion:^(BOOL success, NSString *error) {
        ok = success;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    return ok;
}

// ============================================================
// Helper: text input sync
// ============================================================
static BOOL input_text_sync(NSString *text) {
    __block BOOL ok = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[TextInputManager sharedInstance] inputText:text completion:^(BOOL success, NSString *error) {
        ok = success;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
    return ok;
}

// ============================================================
// Lua function implementations
// ============================================================

static int ios_screenshot(lua_State *L) {
    NSDictionary *payload = [[ScreenManager sharedInstance] takeScreenshotPayload];
    NSString *b64 = payload[@"data"];
    if (b64) {
        lua_pushstring(L, [b64 UTF8String]);
    } else {
        lua_pushnil(L);
    }
    return 1;
}

static int ios_tap(lua_State *L) {
    double x = luaL_checknumber(L, 1);
    double y = luaL_checknumber(L, 2);
    BOOL ok = tap_sync((CGFloat)x, (CGFloat)y);
    lua_pushboolean(L, ok);
    return 1;
}

static int ios_swipe(lua_State *L) {
    double fromX = luaL_checknumber(L, 1);
    double fromY = luaL_checknumber(L, 2);
    double toX   = luaL_checknumber(L, 3);
    double toY   = luaL_checknumber(L, 4);
    double duration = luaL_optnumber(L, 5, 300);
    int steps       = (int)luaL_optinteger(L, 6, 20);

    __block BOOL ok = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[IOSMCPHIDManager sharedInstance] swipeFromPoint:CGPointMake(fromX, fromY)
                                              toPoint:CGPointMake(toX, toY)
                                             duration:duration
                                                steps:steps
                                           completion:^(BOOL success, NSString *error) {
        ok = success;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    lua_pushboolean(L, ok);
    return 1;
}

static int ios_long_press(lua_State *L) {
    double x = luaL_checknumber(L, 1);
    double y = luaL_checknumber(L, 2);
    double duration = luaL_optnumber(L, 3, 1000);

    __block BOOL ok = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[IOSMCPHIDManager sharedInstance] longPressAtPoint:CGPointMake(x, y)
                                               duration:duration
                                             completion:^(BOOL success, NSString *error) {
        ok = success;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    lua_pushboolean(L, ok);
    return 1;
}

static int ios_double_tap(lua_State *L) {
    double x = luaL_checknumber(L, 1);
    double y = luaL_checknumber(L, 2);
    double interval = luaL_optnumber(L, 3, 200);

    __block BOOL ok = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[IOSMCPHIDManager sharedInstance] doubleTapAtPoint:CGPointMake(x, y)
                                               interval:interval
                                             completion:^(BOOL success, NSString *error) {
        ok = success;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    lua_pushboolean(L, ok);
    return 1;
}

static int ios_drag(lua_State *L) {
    double fromX = luaL_checknumber(L, 1);
    double fromY = luaL_checknumber(L, 2);
    double toX   = luaL_checknumber(L, 3);
    double toY   = luaL_checknumber(L, 4);
    double holdDuration = luaL_optnumber(L, 5, 200);
    double moveDuration = luaL_optnumber(L, 6, 500);
    int steps = (int)luaL_optinteger(L, 7, 30);

    __block BOOL ok = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[IOSMCPHIDManager sharedInstance] dragFromPoint:CGPointMake(fromX, fromY)
                                             toPoint:CGPointMake(toX, toY)
                                        holdDuration:holdDuration
                                        moveDuration:moveDuration
                                               steps:steps
                                          completion:^(BOOL success, NSString *error) {
        ok = success;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
    lua_pushboolean(L, ok);
    return 1;
}

static int ios_input_text(lua_State *L) {
    const char *text = luaL_checkstring(L, 1);
    BOOL ok = input_text_sync([NSString stringWithUTF8String:text]);
    lua_pushboolean(L, ok);
    return 1;
}

static int ios_type_text(lua_State *L) {
    const char *text = luaL_checkstring(L, 1);
    double delayMs = luaL_optnumber(L, 2, 50);

    __block BOOL ok = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[TextInputManager sharedInstance] typeText:[NSString stringWithUTF8String:text]
                                       delayMs:delayMs
                                    completion:^(BOOL success, NSString *error) {
        ok = success;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
    lua_pushboolean(L, ok);
    return 1;
}

static int ios_press_key(lua_State *L) {
    const char *key = luaL_checkstring(L, 1);

    __block BOOL ok = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[TextInputManager sharedInstance] pressKey:[NSString stringWithUTF8String:key]
                                    completion:^(BOOL success, NSString *error) {
        ok = success;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    lua_pushboolean(L, ok);
    return 1;
}

static int ios_press_home(lua_State *L) {
    double duration = luaL_optnumber(L, 1, 100);
    BOOL ok = press_button_sync(HIDButtonHome, duration);
    lua_pushboolean(L, ok);
    return 1;
}

static int ios_press_power(lua_State *L) {
    double duration = luaL_optnumber(L, 1, 100);
    BOOL ok = press_button_sync(HIDButtonPower, duration);
    lua_pushboolean(L, ok);
    return 1;
}

static int ios_press_volume_up(lua_State *L) {
    double duration = luaL_optnumber(L, 1, 100);
    BOOL ok = press_button_sync(HIDButtonVolumeUp, duration);
    lua_pushboolean(L, ok);
    return 1;
}

static int ios_press_volume_down(lua_State *L) {
    double duration = luaL_optnumber(L, 1, 100);
    BOOL ok = press_button_sync(HIDButtonVolumeDown, duration);
    lua_pushboolean(L, ok);
    return 1;
}

static int ios_wake_and_home(lua_State *L) {
    // Call wake_and_home via the HID sequence directly
    // Press power
    press_button_sync(HIDButtonPower, 100);
    usleep(300 * 1000);
    // Press home
    BOOL ok = press_button_sync(HIDButtonHome, 100);
    usleep(250 * 1000);
    lua_pushboolean(L, ok);
    return 1;
}

static int ios_toggle_mute(lua_State *L) {
    BOOL ok = press_button_sync(HIDButtonMute, 100);
    lua_pushboolean(L, ok);
    return 1;
}

static int ios_launch_app(lua_State *L) {
    const char *bundleId = luaL_checkstring(L, 1);
    NSError *error = nil;
    BOOL ok = [[AppManager sharedInstance] launchApp:[NSString stringWithUTF8String:bundleId]
                                               error:&error];
    if (ok) {
        lua_pushboolean(L, YES);
    } else {
        lua_pushnil(L);
        lua_pushstring(L, [[error localizedDescription] UTF8String]);
        return 2;
    }
    return 1;
}

static int ios_kill_app(lua_State *L) {
    const char *bundleId = luaL_checkstring(L, 1);
    NSError *error = nil;
    BOOL ok = [[AppManager sharedInstance] killApp:[NSString stringWithUTF8String:bundleId]
                                             error:&error];
    if (ok) {
        lua_pushboolean(L, YES);
    } else {
        lua_pushnil(L);
        lua_pushstring(L, [[error localizedDescription] UTF8String]);
        return 2;
    }
    return 1;
}

static int ios_list_apps(lua_State *L) {
    const char *type = luaL_optstring(L, 1, "all");
    NSArray *apps = [[AppManager sharedInstance] listInstalledApps:[NSString stringWithUTF8String:type]];
    push_objc_value(L, apps ?: @[]);
    return 1;
}

static int ios_list_running_apps(lua_State *L) {
    NSArray *apps = [[AppManager sharedInstance] listRunningApps];
    push_objc_value(L, apps ?: @[]);
    return 1;
}

static int ios_get_frontmost_app(lua_State *L) {
    NSDictionary *app = [[AppManager sharedInstance] getFrontmostApp];
    push_objc_value(L, app ?: [NSNull null]);
    return 1;
}

static int ios_get_app_info(lua_State *L) {
    const char *bundleId = luaL_checkstring(L, 1);
    NSError *error = nil;
    NSDictionary *info = [[AppManager sharedInstance] appInfoForBundleId:[NSString stringWithUTF8String:bundleId]
                                                                   error:&error];
    if (info) {
        push_objc_value(L, info);
    } else {
        lua_pushnil(L);
        lua_pushstring(L, [[error localizedDescription] UTF8String]);
        return 2;
    }
    return 1;
}

static int ios_install_app(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    NSError *error = nil;
    BOOL ok = [[AppManager sharedInstance] installApp:[NSString stringWithUTF8String:path]
                                                error:&error];
    if (ok) {
        lua_pushboolean(L, YES);
    } else {
        lua_pushnil(L);
        lua_pushstring(L, [[error localizedDescription] UTF8String]);
        return 2;
    }
    return 1;
}

static int ios_uninstall_app(lua_State *L) {
    const char *bundleId = luaL_checkstring(L, 1);
    NSError *error = nil;
    BOOL ok = [[AppManager sharedInstance] uninstallApp:[NSString stringWithUTF8String:bundleId]
                                                  error:&error];
    if (ok) {
        lua_pushboolean(L, YES);
    } else {
        lua_pushnil(L);
        lua_pushstring(L, [[error localizedDescription] UTF8String]);
        return 2;
    }
    return 1;
}

static int ios_get_ui_elements(lua_State *L) {
    int maxElements = (int)luaL_optinteger(L, 1, 200);
    BOOL visibleOnly = (BOOL)lua_toboolean(L, 2);
    if (lua_isnone(L, 2)) visibleOnly = YES;
    BOOL clickableOnly = (BOOL)lua_toboolean(L, 3);

    __block NSDictionary *result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[AccessibilityManager sharedInstance] getCompactUIElementsWithMaxElements:maxElements
                                                                  visibleOnly:visibleOnly
                                                                clickableOnly:clickableOnly
                                                                   completion:^(NSDictionary *elements) {
        result = elements;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    push_objc_value(L, result ?: [NSNull null]);
    return 1;
}

static int ios_get_element_at_point(lua_State *L) {
    double x = luaL_checknumber(L, 1);
    double y = luaL_checknumber(L, 2);

    __block NSDictionary *result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[AccessibilityManager sharedInstance] getElementAtPoint:CGPointMake(x, y)
                                                  completion:^(NSDictionary *element) {
        result = element;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    push_objc_value(L, result ?: [NSNull null]);
    return 1;
}

static int ios_find_element(lua_State *L) {
    const char *textC = luaL_optstring(L, 1, "");
    const char *identifierC = luaL_optstring(L, 2, "");

    NSString *text = [NSString stringWithUTF8String:textC];
    NSString *identifier = [NSString stringWithUTF8String:identifierC];

    __block NSDictionary *elements = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[AccessibilityManager sharedInstance] getCompactUIElementsWithMaxElements:500
                                                                  visibleOnly:YES
                                                                clickableOnly:NO
                                                                   completion:^(NSDictionary *result) {
        elements = result;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));

    NSArray *items = elements[@"elements"];
    if (!items || items.count == 0) {
        lua_pushnil(L);
        return 1;
    }

    for (NSDictionary *item in items) {
        NSString *label = item[@"label"] ?: @"";
        NSString *elemId = item[@"identifier"] ?: @"";

        BOOL match = NO;
        if (identifier.length > 0) {
            match = [elemId isEqualToString:identifier];
        } else if (text.length > 0) {
            match = ([label rangeOfString:text options:NSCaseInsensitiveSearch].location != NSNotFound);
        }

        if (match) {
            push_objc_value(L, item);
            return 1;
        }
    }

    lua_pushnil(L);
    return 1;
}

static int ios_wait_for_element(lua_State *L) {
    const char *textC = luaL_checkstring(L, 1);
    double timeoutMs = luaL_optnumber(L, 2, 5000);
    double intervalMs = luaL_optnumber(L, 3, 500);

    NSString *text = [NSString stringWithUTF8String:textC];
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + timeoutMs / 1000.0;

    while (CFAbsoluteTimeGetCurrent() < deadline) {
        __block NSDictionary *elements = nil;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [[AccessibilityManager sharedInstance] getCompactUIElementsWithMaxElements:500
                                                                      visibleOnly:YES
                                                                    clickableOnly:NO
                                                                       completion:^(NSDictionary *result) {
            elements = result;
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));

        NSArray *items = elements[@"elements"];
        for (NSDictionary *item in items) {
            NSString *label = item[@"label"] ?: @"";
            if ([label rangeOfString:text options:NSCaseInsensitiveSearch].location != NSNotFound) {
                lua_pushboolean(L, YES);
                push_objc_value(L, item);
                return 2;
            }
        }

        usleep((useconds_t)(intervalMs * 1000));
    }

    lua_pushboolean(L, NO);
    return 1;
}

static int ios_wait_for_disappear(lua_State *L) {
    const char *textC = luaL_checkstring(L, 1);
    double timeoutMs = luaL_optnumber(L, 2, 5000);
    double intervalMs = luaL_optnumber(L, 3, 500);

    NSString *text = [NSString stringWithUTF8String:textC];
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + timeoutMs / 1000.0;

    while (CFAbsoluteTimeGetCurrent() < deadline) {
        __block NSDictionary *elements = nil;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [[AccessibilityManager sharedInstance] getCompactUIElementsWithMaxElements:500
                                                                      visibleOnly:YES
                                                                    clickableOnly:NO
                                                                       completion:^(NSDictionary *result) {
            elements = result;
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));

        NSArray *items = elements[@"elements"];
        BOOL found = NO;
        for (NSDictionary *item in items) {
            NSString *label = item[@"label"] ?: @"";
            if ([label rangeOfString:text options:NSCaseInsensitiveSearch].location != NSNotFound) {
                found = YES;
                break;
            }
        }

        if (!found) {
            lua_pushboolean(L, YES);
            return 1;
        }

        usleep((useconds_t)(intervalMs * 1000));
    }

    lua_pushboolean(L, NO);
    return 1;
}

static int ios_ocr_screen(lua_State *L) {
    const char *languages = luaL_optstring(L, 1, "zh-Hans,en");
    double minConfidence = luaL_optnumber(L, 2, 0.5);

    NSError *error = nil;
    NSDictionary *result = [[OCRManager sharedInstance]
        recognizeTextWithLanguages:[NSString stringWithUTF8String:languages]
                     minConfidence:minConfidence
                            region:CGRectNull
                              fast:NO
                             error:&error];
    if (result) {
        push_objc_value(L, result);
    } else {
        lua_pushnil(L);
        lua_pushstring(L, [[error localizedDescription] UTF8String]);
        return 2;
    }
    return 1;
}

static int ios_get_screen_info(lua_State *L) {
    NSDictionary *info = [[ScreenManager sharedInstance] screenInfo];
    push_objc_value(L, info ?: @{});
    return 1;
}

static int ios_get_clipboard(lua_State *L) {
    NSDictionary *content = [[ClipboardManager sharedInstance] readClipboard];
    push_objc_value(L, content ?: @{});
    return 1;
}

static int ios_set_clipboard(lua_State *L) {
    const char *text = luaL_checkstring(L, 1);
    [[ClipboardManager sharedInstance] writeText:[NSString stringWithUTF8String:text]];
    lua_pushboolean(L, YES);
    return 1;
}

static int ios_open_url(lua_State *L) {
    const char *url = luaL_checkstring(L, 1);
    NSError *error = nil;
    BOOL ok = [[AppManager sharedInstance] openURL:[NSString stringWithUTF8String:url]
                                             error:&error];
    if (ok) {
        lua_pushboolean(L, YES);
    } else {
        lua_pushnil(L);
        lua_pushstring(L, [[error localizedDescription] UTF8String]);
        return 2;
    }
    return 1;
}

static int ios_get_device_info(lua_State *L) {
    // Gather device info
    UIDevice *device = [UIDevice currentDevice];
    struct utsname sysinfo;
    uname(&sysinfo);

    NSDictionary *info = @{
        @"name": device.name ?: @"",
        @"systemName": device.systemName ?: @"",
        @"systemVersion": device.systemVersion ?: @"",
        @"model": device.model ?: @"",
        @"localizedModel": device.localizedModel ?: @"",
        @"identifierForVendor": [[device identifierForVendor] UUIDString] ?: @"",
        @"machine": [NSString stringWithUTF8String:sysinfo.machine],
        @"nodename": [NSString stringWithUTF8String:sysinfo.nodename],
        @"release": [NSString stringWithUTF8String:sysinfo.release],
        @"version": [NSString stringWithUTF8String:sysinfo.version],
    };
    push_objc_value(L, info);
    return 1;
}

static int ios_run_command(lua_State *L) {
    const char *cmd = luaL_checkstring(L, 1);
    double timeout = luaL_optnumber(L, 2, 10);

    MCPRunProcessResult result = MCPRunProcess([NSString stringWithUTF8String:cmd],
                                               timeout, nil);
    lua_newtable(L);
    lua_pushstring(L, [result.stdoutStr UTF8String] ?: "");
    lua_setfield(L, -2, "stdout");
    lua_pushstring(L, [result.stderrStr UTF8String] ?: "");
    lua_setfield(L, -2, "stderr");
    lua_pushinteger(L, result.exitCode);
    lua_setfield(L, -2, "exit_code");
    return 1;
}

static int ios_get_brightness(lua_State *L) {
    lua_pushnumber(L, [[UIScreen mainScreen] brightness]);
    return 1;
}

static int ios_set_brightness(lua_State *L) {
    double val = luaL_checknumber(L, 1);
    if (val < 0) val = 0;
    if (val > 1) val = 1;
    [[UIScreen mainScreen] setBrightness:(CGFloat)val];
    lua_pushboolean(L, YES);
    return 1;
}

static int ios_get_volume(lua_State *L) {
    // Use AVSystemController via private API
    void *handle = dlopen("/System/Library/PrivateFrameworks/Celestial.framework/Celestial", RTLD_LAZY);
    if (!handle) {
        handle = dlopen("/System/Library/PrivateFrameworks/MediaExperience.framework/MediaExperience", RTLD_LAZY);
    }
    if (handle) {
        Class avClass = objc_getClass("AVSystemController");
        if (avClass) {
            id controller = [avClass performSelector:@selector(sharedAVSystemController)];
            if (controller) {
                float volume = 0.5f;
                NSNumber *volNum = [controller valueForKey:@"volume"];
                if (volNum) volume = [volNum floatValue];
                lua_pushnumber(L, volume);
                dlclose(handle);
                return 1;
            }
        }
        dlclose(handle);
    }
    lua_pushnumber(L, 0.5);
    return 1;
}

static int ios_set_volume(lua_State *L) {
    double val = luaL_checknumber(L, 1);
    if (val < 0) val = 0;
    if (val > 1) val = 1;

    void *handle = dlopen("/System/Library/PrivateFrameworks/Celestial.framework/Celestial", RTLD_LAZY);
    if (!handle) {
        handle = dlopen("/System/Library/PrivateFrameworks/MediaExperience.framework/MediaExperience", RTLD_LAZY);
    }
    if (handle) {
        Class avClass = objc_getClass("AVSystemController");
        if (avClass) {
            id controller = [avClass performSelector:@selector(sharedAVSystemController)];
            if (controller) {
                [controller setValue:@(val) forKey:@"volume"];
                lua_pushboolean(L, YES);
                dlclose(handle);
                return 1;
            }
        }
        dlclose(handle);
    }
    lua_pushboolean(L, NO);
    return 1;
}

static int ios_read_file(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    int maxBytes = (int)luaL_optinteger(L, 2, 512 * 1024);

    NSError *error = nil;
    NSDictionary *result = [[FileSystemManager sharedInstance]
        readFileAtPath:[NSString stringWithUTF8String:path]
              maxBytes:maxBytes
          forceBinary:NO
                 error:&error];
    if (result) {
        push_objc_value(L, result);
    } else {
        lua_pushnil(L);
        if (error) lua_pushstring(L, [[error localizedDescription] UTF8String]);
        else lua_pushstring(L, "read failed");
        return 2;
    }
    return 1;
}

static int ios_write_file(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    const char *content = luaL_checkstring(L, 2);

    NSError *error = nil;
    BOOL ok = [[FileSystemManager sharedInstance]
        writeFileAtPath:[NSString stringWithUTF8String:path]
                content:[NSString stringWithUTF8String:content]
               encoding:@"utf8"
                  error:&error];
    if (ok) {
        lua_pushboolean(L, YES);
    } else {
        lua_pushnil(L);
        if (error) lua_pushstring(L, [[error localizedDescription] UTF8String]);
        else lua_pushstring(L, "write failed");
        return 2;
    }
    return 1;
}

static int ios_list_dir(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);

    NSError *error = nil;
    NSArray *items = [[FileSystemManager sharedInstance]
        listDirectoryAtPath:[NSString stringWithUTF8String:path]
                      error:&error];
    if (items) {
        push_objc_value(L, items);
    } else {
        lua_pushnil(L);
        if (error) lua_pushstring(L, [[error localizedDescription] UTF8String]);
        else lua_pushstring(L, "list_dir failed");
        return 2;
    }
    return 1;
}

static int ios_get_syslog(lua_State *L) {
    const char *process = luaL_optstring(L, 1, "");
    const char *level   = luaL_optstring(L, 2, "debug");
    double lastSeconds  = luaL_optnumber(L, 3, 5);
    int maxLines        = (int)luaL_optinteger(L, 4, 200);

    NSError *error = nil;
    NSDictionary *result = [[LogManager sharedInstance]
        syslogWithProcess:[NSString stringWithUTF8String:process]
                    level:[NSString stringWithUTF8String:level]
              lastSeconds:lastSeconds
                 maxLines:maxLines
                    error:&error];
    if (result) {
        push_objc_value(L, result);
    } else {
        lua_pushnil(L);
        if (error) lua_pushstring(L, [[error localizedDescription] UTF8String]);
        else lua_pushstring(L, "syslog failed");
        return 2;
    }
    return 1;
}

static int ios_get_crash_logs(lua_State *L) {
    const char *bundleId = luaL_optstring(L, 1, "");
    int limit = (int)luaL_optinteger(L, 2, 20);

    NSError *error = nil;
    NSArray *logs = [[LogManager sharedInstance]
        crashLogsForBundleId:[NSString stringWithUTF8String:bundleId]
                       limit:limit
                       error:&error];
    if (logs) {
        push_objc_value(L, logs);
    } else {
        lua_pushnil(L);
        if (error) lua_pushstring(L, [[error localizedDescription] UTF8String]);
        else lua_pushstring(L, "no crash logs");
        return 2;
    }
    return 1;
}

static int ios_read_crash_log(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);

    NSError *error = nil;
    NSString *content = [[LogManager sharedInstance]
        crashLogContentAtPath:[NSString stringWithUTF8String:path]
                        error:&error];
    if (content) {
        lua_pushstring(L, [content UTF8String]);
    } else {
        lua_pushnil(L);
        if (error) lua_pushstring(L, [[error localizedDescription] UTF8String]);
        else lua_pushstring(L, "read crash log failed");
        return 2;
    }
    return 1;
}

static int ios_sleep_ms(lua_State *L) {
    lua_Integer ms = luaL_checkinteger(L, 1);
    if (ms < 0) ms = 0;
    if (ms > 30000) ms = 30000;
    usleep((useconds_t)(ms * 1000));
    return 0;
}

static int ios_log(lua_State *L) {
    const char *msg = luaL_checkstring(L, 1);
    [MCPLogger log:[NSString stringWithFormat:@"[LUA] %s", msg]];
    return 0;
}

// ============================================================
// Function registration table
// ============================================================
static const luaL_Reg ios_funcs[] = {
    {"screenshot",         ios_screenshot},
    {"tap",                ios_tap},
    {"swipe",              ios_swipe},
    {"long_press",         ios_long_press},
    {"double_tap",         ios_double_tap},
    {"drag",               ios_drag},
    {"input_text",         ios_input_text},
    {"type_text",          ios_type_text},
    {"press_key",          ios_press_key},
    {"press_home",         ios_press_home},
    {"press_power",        ios_press_power},
    {"press_volume_up",    ios_press_volume_up},
    {"press_volume_down",  ios_press_volume_down},
    {"wake_and_home",      ios_wake_and_home},
    {"toggle_mute",        ios_toggle_mute},
    {"launch_app",         ios_launch_app},
    {"kill_app",           ios_kill_app},
    {"list_apps",          ios_list_apps},
    {"list_running_apps",  ios_list_running_apps},
    {"get_frontmost_app",  ios_get_frontmost_app},
    {"get_app_info",       ios_get_app_info},
    {"install_app",        ios_install_app},
    {"uninstall_app",      ios_uninstall_app},
    {"get_ui_elements",    ios_get_ui_elements},
    {"get_element_at_point", ios_get_element_at_point},
    {"find_element",       ios_find_element},
    {"wait_for_element",   ios_wait_for_element},
    {"wait_for_disappear", ios_wait_for_disappear},
    {"ocr_screen",         ios_ocr_screen},
    {"get_screen_info",    ios_get_screen_info},
    {"get_clipboard",      ios_get_clipboard},
    {"set_clipboard",      ios_set_clipboard},
    {"open_url",           ios_open_url},
    {"get_device_info",    ios_get_device_info},
    {"run_command",        ios_run_command},
    {"get_brightness",     ios_get_brightness},
    {"set_brightness",     ios_set_brightness},
    {"get_volume",         ios_get_volume},
    {"set_volume",         ios_set_volume},
    {"read_file",          ios_read_file},
    {"write_file",         ios_write_file},
    {"list_dir",           ios_list_dir},
    {"get_syslog",         ios_get_syslog},
    {"get_crash_logs",     ios_get_crash_logs},
    {"read_crash_log",     ios_read_crash_log},
    {"sleep",              ios_sleep_ms},
    {"log",                ios_log},
    {NULL, NULL}
};

// ============================================================
// Output capture: redirect print() to a string buffer
// ============================================================
@interface LuaManager () {
    lua_State *_L;
    NSMutableString *_capturedOutput;
}
@property (nonatomic, strong) NSString *scriptsDirectory;
@end

static int lua_print_captured(lua_State *L) {
    int n = lua_gettop(L);
    lua_getglobal(L, "_capture_buffer");
    luaL_Buffer *b = (luaL_Buffer *)lua_touserdata(L, -1);
    lua_pop(L, 1);

    for (int i = 1; i <= n; i++) {
        size_t len;
        const char *s = luaL_tolstring(L, i, &len);
        if (i > 1) luaL_addstring(b, "\t");
        luaL_addlstring(b, s, len);
        lua_pop(L, 1);
    }
    luaL_addstring(b, "\n");
    return 0;
}

@implementation LuaManager

+ (instancetype)sharedInstance {
    static LuaManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[LuaManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _capturedOutput = [NSMutableString string];

        // Scripts directory: /var/mobile/Documents/ios-mcp/scripts/
        NSString *docDir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        _scriptsDirectory = [[docDir stringByAppendingPathComponent:@"ios-mcp"] stringByAppendingPathComponent:@"scripts"];
    }
    return self;
}

- (void)dealloc {
    if (_L) {
        lua_close(_L);
        _L = NULL;
    }
}

- (lua_State *)ensureLuaState {
    if (_L) return _L;

    _L = luaL_newstate();
    if (!_L) return NULL;

    // Open all standard libraries (safe in our process context)
    luaL_openlibs(_L);

    // Register the "ios" global table
    luaL_newlib(_L, ios_funcs);
    lua_setglobal(_L, "ios");

    return _L;
}

- (NSString *)_ensureScriptsDir {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;
    if (![fm fileExistsAtPath:self.scriptsDirectory]) {
        [fm createDirectoryAtPath:self.scriptsDirectory
      withIntermediateDirectories:YES
                       attributes:nil
                            error:&error];
        if (error) {
            NSLog(@"[LuaManager] Failed to create scripts dir: %@", error);
        }
    }
    return self.scriptsDirectory;
}

- (NSDictionary *)executeScript:(NSString *)script {
    if (script.length == 0) {
        return @{@"success": @NO, @"error": @"Empty script"};
    }

    lua_State *L = [self ensureLuaState];
    if (!L) {
        return @{@"success": @NO, @"error": @"Failed to initialize Lua state"};
    }

    [_capturedOutput setString:@""];
    luaL_Buffer captureBuf;
    luaL_buffinit(L, &captureBuf);

    // Push capture buffer as a global
    lua_pushlightuserdata(L, &captureBuf);
    lua_setglobal(L, "_capture_buffer");

    // Override print with our captured version
    lua_pushcfunction(L, lua_print_captured);
    lua_setglobal(L, "print");

    // Compile and run
    int loadErr = luaL_loadstring(L, [script UTF8String]);
    if (loadErr != LUA_OK) {
        const char *errMsg = lua_tostring(L, -1);
        NSString *error = [NSString stringWithUTF8String:errMsg ?: "unknown compile error"];
        lua_pop(L, 1);
        return @{@"success": @NO, @"error": error, @"type": @"compile_error"};
    }

    int runErr = lua_pcall(L, 0, 1, 0);
    if (runErr != LUA_OK) {
        const char *errMsg = lua_tostring(L, -1);
        NSString *error = [NSString stringWithUTF8String:errMsg ?: "unknown runtime error"];
        lua_pop(L, 1);

        // Collect any captured output even on error
        luaL_pushresult(&captureBuf);
        const char *output = lua_tostring(L, -1);
        NSString *outputStr = output ? [NSString stringWithUTF8String:output] : @"";
        lua_pop(L, 1);

        return @{
            @"success": @NO,
            @"error": error,
            @"type": @"runtime_error",
            @"output": outputStr
        };
    }

    // Get return value(s)
    id result = nil;
    if (!lua_isnone(L, -1)) {
        result = to_objc_value(L, -1);
    }
    lua_pop(L, 1);

    // Collect captured output
    luaL_pushresult(&captureBuf);
    const char *output = lua_tostring(L, -1);
    NSString *outputStr = output ? [NSString stringWithUTF8String:output] : @"";
    lua_pop(L, 1);

    // Clean up globals
    lua_pushnil(L);
    lua_setglobal(L, "_capture_buffer");
    lua_pushnil(L);
    lua_setglobal(L, "print");

    NSMutableDictionary *response = [NSMutableDictionary dictionary];
    response[@"success"] = @YES;
    if (result) response[@"result"] = result;
    response[@"output"] = outputStr;

    return response;
}

- (NSArray<NSString *> *)listScripts {
    [self _ensureScriptsDir];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error = nil;
    NSArray *files = [fm contentsOfDirectoryAtPath:self.scriptsDirectory error:&error];
    if (!files) return @[];

    NSMutableArray *scripts = [NSMutableArray array];
    for (NSString *file in files) {
        if ([file.pathExtension isEqualToString:@"lua"]) {
            [scripts addObject:file];
        }
    }
    return [scripts sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

- (NSString *)readScriptNamed:(NSString *)name {
    [self _ensureScriptsDir];

    if (![name.pathExtension isEqualToString:@"lua"]) {
        name = [name stringByAppendingPathExtension:@"lua"];
    }
    NSString *path = [self.scriptsDirectory stringByAppendingPathComponent:name];

    NSError *error = nil;
    NSString *content = [NSString stringWithContentsOfFile:path
                                                  encoding:NSUTF8StringEncoding
                                                     error:&error];
    return content;
}

- (BOOL)saveScript:(NSString *)script named:(NSString *)name error:(NSError **)error {
    [self _ensureScriptsDir];

    if (![name.pathExtension isEqualToString:@"lua"]) {
        name = [name stringByAppendingPathExtension:@"lua"];
    }
    NSString *path = [self.scriptsDirectory stringByAppendingPathComponent:name];

    return [script writeToFile:path
                    atomically:YES
                      encoding:NSUTF8StringEncoding
                         error:error];
}

- (BOOL)deleteScriptNamed:(NSString *)name error:(NSError **)error {
    [self _ensureScriptsDir];

    if (![name.pathExtension isEqualToString:@"lua"]) {
        name = [name stringByAppendingPathExtension:@"lua"];
    }
    NSString *path = [self.scriptsDirectory stringByAppendingPathComponent:name];

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path]) return YES;
    return [fm removeItemAtPath:path error:error];
}

@end
