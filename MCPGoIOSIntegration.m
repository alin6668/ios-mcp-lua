#import "MCPGoIOSIntegration.h"
#import "MCPServer.h"
#import "MCPServerInternal.h"
#import "MCPLogger.h"
#import <UIKit/UIKit.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <sys/loadavg.h>
#import <mach/mach.h>
#import <mach/processor_info.h>
#import <mach/mach_host.h>
#import <dlfcn.h>
#import <unistd.h>
#import <spawn.h>
#import <sys/wait.h>
#import <CoreLocation/CoreLocation.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <CoreTelephony/CTCarrier.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <SystemConfiguration/CaptiveNetwork.h>

// ============================================================================
// Private / SPIs (used via dlopen/dlsym on jailbroken devices)
// ============================================================================

// Location simulation
static BOOL DTSimulateLocation(double latitude, double longitude) {
    // On jailbroken device, use CLLocationManager's private simulation SPI
    void *clHandle = dlopen("/System/Library/Frameworks/CoreLocation.framework/CoreLocation", RTLD_LAZY);
    if (clHandle) {
        Class cls = NSClassFromString(@"CLLocationManager");
        if (cls) {
            id manager = [[cls alloc] init];
            SEL simSel = NSSelectorFromString(@"_simulateLocationWithDistanceFilter:coordinate:speed:course:altitude:horizontalAccuracy:verticalAccuracy:");
            if ([manager respondsToSelector:simSel]) {
                CLLocationCoordinate2D coord = CLLocationCoordinate2DMake(latitude, longitude);
                NSMethodSignature *sig = [manager methodSignatureForSelector:simSel];
                if (sig) {
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                    [inv setTarget:manager];
                    [inv setSelector:simSel];
                    double dist = 0, speed = -1, course = -1, alt = 0, hAcc = 5, vAcc = -1;
                    [inv setArgument:&dist atIndex:2];
                    [inv setArgument:&coord atIndex:3];
                    [inv setArgument:&speed atIndex:4];
                    [inv setArgument:&course atIndex:5];
                    [inv setArgument:&alt atIndex:6];
                    [inv setArgument:&hAcc atIndex:7];
                    [inv setArgument:&vAcc atIndex:8];
                    [inv invoke];
                    dlclose(clHandle);
                    return YES;
                }
            }
        }
        dlclose(clHandle);
    }
    return NO;
}

static BOOL DTResetLocation(void) {
    // Reset simulated location by stopping the simulation
    void *clHandle = dlopen("/System/Library/Frameworks/CoreLocation.framework/CoreLocation", RTLD_LAZY);
    if (clHandle) {
        Class cls = NSClassFromString(@"CLLocationManager");
        if (cls) {
            id manager = [[cls alloc] init];
            SEL stopSel = NSSelectorFromString(@"_stopSimulatingLocation");
            if ([manager respondsToSelector:stopSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [manager performSelector:stopSel];
#pragma clang diagnostic pop
                dlclose(clHandle);
                return YES;
            }
        }
        dlclose(clHandle);
    }
    return NO;
}

// ============================================================================
// Process listing via sysctl
// ============================================================================

static NSArray<NSDictionary *> *DTGetProcessList(void) {
    NSMutableArray *processes = [NSMutableArray array];

    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t size = 0;

    if (sysctl(mib, 4, NULL, &size, NULL, 0) < 0) {
        return @[];
    }

    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
    if (!procs) return @[];

    if (sysctl(mib, 4, procs, &size, NULL, 0) < 0) {
        free(procs);
        return @[];
    }

    int count = (int)(size / sizeof(struct kinfo_proc));
    for (int i = 0; i < count; i++) {
        struct kinfo_proc *p = &procs[i];
        if (p->kp_proc.p_pid == 0) continue;

        NSString *name = [NSString stringWithCString:p->kp_proc.p_comm encoding:NSUTF8StringEncoding] ?: @"?";

        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"pid"] = @(p->kp_proc.p_pid);
        entry[@"name"] = name;
        entry[@"ppid"] = @(p->kp_eproc.e_ppid);
        entry[@"start_time"] = @(p->kp_proc.p_starttime.tv_sec);

        // Get process group
        if (p->kp_eproc.e_pgid > 0) {
            entry[@"pgid"] = @(p->kp_eproc.e_pgid);
        }

        [processes addObject:entry];
    }

    free(procs);
    return processes;
}

// ============================================================================
// CPU usage metrics via host_statistics
// ============================================================================

static NSDictionary *DTGetCPUUsage(void) {
    kern_return_t kr;
    mach_port_t host = mach_host_self();
    processor_info_array_t infoArray = NULL;
    mach_msg_type_number_t infoCount = 0;
    natural_t processorCount = 0;

    kr = host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &processorCount, &infoArray, &infoCount);
    if (kr != KERN_SUCCESS || infoCount == 0) {
        return nil;
    }

    double totalUser = 0, totalSystem = 0, totalIdle = 0, totalNice = 0;
    processor_cpu_load_info_t cpuInfo = (processor_cpu_load_info_t)infoArray;

    for (natural_t i = 0; i < processorCount; i++) {
        totalUser   += (double)cpuInfo[i].cpu_ticks[CPU_STATE_USER];
        totalSystem += (double)cpuInfo[i].cpu_ticks[CPU_STATE_SYSTEM];
        totalIdle   += (double)cpuInfo[i].cpu_ticks[CPU_STATE_IDLE];
        totalNice   += (double)cpuInfo[i].cpu_ticks[CPU_STATE_NICE];
    }

    vm_deallocate(mach_task_self(), (vm_address_t)infoArray, infoCount * sizeof(*infoArray));

    double total = totalUser + totalSystem + totalIdle + totalNice;
    if (total == 0) return nil;

    return @{
        @"cpu_count": @(processorCount),
        @"user_pct":   @(totalUser   / total * 100.0),
        @"system_pct": @(totalSystem / total * 100.0),
        @"idle_pct":   @(totalIdle   / total * 100.0),
        @"nice_pct":   @(totalNice   / total * 100.0),
        @"total_ticks": @(total),
    };
}

// ============================================================================
// Memory stats via host_statistics64
// ============================================================================

static NSDictionary *DTGetMemoryStats(void) {
    mach_port_t host = mach_host_self();
    vm_size_t pageSize;
    host_page_size(host, &pageSize);

    vm_statistics64_data_t vmStat;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;

    if (host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vmStat, &count) != KERN_SUCCESS) {
        return nil;
    }

    unsigned long long physicalMemory = [NSProcessInfo processInfo].physicalMemory;

    return @{
        @"total_bytes": @(physicalMemory),
        @"total_mb": @(physicalMemory / (1024.0 * 1024.0)),
        @"free_bytes": @(vmStat.free_count * pageSize),
        @"free_mb": @(vmStat.free_count * pageSize / (1024.0 * 1024.0)),
        @"active_bytes": @(vmStat.active_count * pageSize),
        @"inactive_bytes": @(vmStat.inactive_count * pageSize),
        @"wired_bytes": @(vmStat.wire_count * pageSize),
        @"compressed_bytes": @(vmStat.compressor_page_count * pageSize),
        @"page_size": @(pageSize),
        @"pageins": @(vmStat.pageins),
        @"pageouts": @(vmStat.pageouts),
    };
}

// ============================================================================
// System load average
// ============================================================================

static NSDictionary *DTGetLoadAverage(void) {
    struct loadavg load;
    size_t size = sizeof(load);

    if (sysctlbyname("vm.loadavg", &load, &size, NULL, 0) < 0) {
        // Fallback: try getloadavg()
        double avg[3];
        if (getloadavg(avg, 3) < 0) return nil;
        return @{
            @"load_1min": @(avg[0]),
            @"load_5min": @(avg[1]),
            @"load_15min": @(avg[2]),
        };
    }

    return @{
        @"load_1min": @((double)load.ldavg[0] / (double)load.fscale),
        @"load_5min": @((double)load.ldavg[1] / (double)load.fscale),
        @"load_15min": @((double)load.ldavg[2] / (double)load.fscale),
    };
}

// ============================================================================
// Network info via SCNetworkReachability & CoreTelephony
// ============================================================================

static NSDictionary *DTGetNetworkInfo(void) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];

    // WiFi
    {
        void *scHandle = dlopen("/System/Library/Frameworks/SystemConfiguration.framework/SystemConfiguration", RTLD_LAZY);
        if (scHandle) {
            // Check WiFi Reachability
            SCNetworkReachabilityRef reachability = SCNetworkReachabilityCreateWithName(kCFAllocatorDefault, "apple.com");
            if (reachability) {
                SCNetworkReachabilityFlags flags;
                if (SCNetworkReachabilityGetFlags(reachability, &flags)) {
                    info[@"reachable"] = @((flags & kSCNetworkReachabilityFlagsReachable) != 0);
                    info[@"wifi"] = @((flags & kSCNetworkReachabilityFlagsIsWWAN) == 0 && (flags & kSCNetworkReachabilityFlagsReachable) != 0);
                    info[@"cellular"] = @((flags & kSCNetworkReachabilityFlagsIsWWAN) != 0);

                    if (flags & kSCNetworkReachabilityFlagsConnectionRequired) {
                        info[@"connection_required"] = @YES;
                    }
                }
                CFRelease(reachability);
            }
            dlclose(scHandle);
        }
    }

    // Cellular carrier info
    {
        CTTelephonyNetworkInfo *telInfo = [[CTTelephonyNetworkInfo alloc] init];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        CTCarrier *carrier = telInfo.subscriberCellularProvider;
#pragma clang diagnostic pop
        if (carrier) {
            info[@"carrier_name"] = carrier.carrierName ?: @"-";
            info[@"carrier_mcc"] = carrier.mobileCountryCode ?: @"-";
            info[@"carrier_mnc"] = carrier.mobileNetworkCode ?: @"-";
            info[@"carrier_allows_voip"] = @(carrier.allowsVOIP);
            info[@"carrier_iso_country"] = carrier.isoCountryCode ?: @"-";
        }
        if (@available(iOS 12.0, *)) {
            NSDictionary<NSString *,NSString *> *radio = telInfo.serviceCurrentRadioAccessTechnology;
            if (radio.count > 0) {
                info[@"radio_technology"] = radio.allValues.firstObject ?: @"-";
            }
        }
    }

    // Host name
    info[@"hostname"] = [[NSProcessInfo processInfo] hostName] ?: @"-";

    return info;
}

// ============================================================================
// Accessibility toggles
// ============================================================================

static BOOL DTSetAssistiveTouch(BOOL enabled) {
    // On jailbroken device, we can write directly to preferences
    // SpringBoard reads this key to show/hide the assistive touch button
    CFPreferencesSetAppValue(CFSTR("AssistiveTouchEnabledByiTunes"),
                             enabled ? kCFBooleanTrue : kCFBooleanFalse,
                             CFSTR("com.apple.Accessibility"));
    CFPreferencesAppSynchronize(CFSTR("com.apple.Accessibility"));

    // Also try to notify accessibility framework
    void *axHandle = dlopen("/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities", RTLD_LAZY);
    if (axHandle) {
        // Try AXSettings
        Class axSettings = NSClassFromString(@"AXSettings");
        if (axSettings) {
            SEL setSel = NSSelectorFromString(@"setAssistiveTouchEnabled:");
            id sharedInstance = [axSettings performSelector:NSSelectorFromString(@"sharedInstance")];
            if (sharedInstance && [sharedInstance respondsToSelector:setSel]) {
                NSMethodSignature *sig = [sharedInstance methodSignatureForSelector:setSel];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:sharedInstance];
                [inv setSelector:setSel];
                [inv setArgument:&enabled atIndex:2];
                [inv invoke];
            }
        }

        // Notify SpringBoard via Darwin notification
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFSTR("com.apple.accessibility.cache.assistiveTouch"),
                                             NULL, NULL, YES);
        dlclose(axHandle);
    }

    return YES;
}

static BOOL DTSetVoiceOver(BOOL enabled) {
    CFPreferencesSetAppValue(CFSTR("VoiceOverTouchEnabledByiTunes"),
                             enabled ? kCFBooleanTrue : kCFBooleanFalse,
                             CFSTR("com.apple.Accessibility"));
    CFPreferencesAppSynchronize(CFSTR("com.apple.Accessibility"));

    void *axHandle = dlopen("/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities", RTLD_LAZY);
    if (axHandle) {
        Class axSettings = NSClassFromString(@"AXSettings");
        if (axSettings) {
            SEL setSel = NSSelectorFromString(@"setVoiceOverTouchEnabled:");
            id sharedInstance = [axSettings performSelector:NSSelectorFromString(@"sharedInstance")];
            if (sharedInstance && [sharedInstance respondsToSelector:setSel]) {
                NSMethodSignature *sig = [sharedInstance methodSignatureForSelector:setSel];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:sharedInstance];
                [inv setSelector:setSel];
                [inv setArgument:&enabled atIndex:2];
                [inv invoke];
            }
        }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFSTR("com.apple.accessibility.cache.voiceOver"),
                                             NULL, NULL, YES);
        dlclose(axHandle);
    }

    return YES;
}

static BOOL DTSetZoom(BOOL enabled) {
    CFPreferencesSetAppValue(CFSTR("ZoomTouchEnabledByiTunes"),
                             enabled ? kCFBooleanTrue : kCFBooleanFalse,
                             CFSTR("com.apple.Accessibility"));
    CFPreferencesAppSynchronize(CFSTR("com.apple.Accessibility"));

    void *axHandle = dlopen("/System/Library/PrivateFrameworks/AccessibilityUtilities.framework/AccessibilityUtilities", RTLD_LAZY);
    if (axHandle) {
        Class axSettings = NSClassFromString(@"AXSettings");
        if (axSettings) {
            SEL setSel = NSSelectorFromString(@"setZoomTouchEnabled:");
            id sharedInstance = [axSettings performSelector:NSSelectorFromString(@"sharedInstance")];
            if (sharedInstance && [sharedInstance respondsToSelector:setSel]) {
                NSMethodSignature *sig = [sharedInstance methodSignatureForSelector:setSel];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                [inv setTarget:sharedInstance];
                [inv setSelector:setSel];
                [inv setArgument:&enabled atIndex:2];
                [inv invoke];
            }
        }
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFSTR("com.apple.accessibility.cache.zoom"),
                                             NULL, NULL, YES);
        dlclose(axHandle);
    }

    return YES;
}

// ============================================================================
// Language / Locale setting
// ============================================================================

static BOOL DTSetLanguage(NSString *languageCode) {
    if (!languageCode.length) return NO;

    // Write to global preferences
    NSArray *langs = @[languageCode];
    CFPreferencesSetAppValue(CFSTR("AppleLanguages"), (__bridge CFPropertyListRef)langs,
                             kCFPreferencesAnyApplication);
    CFPreferencesAppSynchronize(kCFPreferencesAnyApplication);

    // Notify the system
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("AppleLanguageChanged"),
                                         NULL, NULL, YES);

    return YES;
}

static BOOL DTSetLocale(NSString *localeId) {
    if (!localeId.length) return NO;

    CFPreferencesSetAppValue(CFSTR("AppleLocale"), (__bridge CFStringRef)localeId,
                             kCFPreferencesAnyApplication);
    CFPreferencesAppSynchronize(kCFPreferencesAnyApplication);

    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("AppleLocaleChanged"),
                                         NULL, NULL, YES);

    return YES;
}

static NSDictionary *DTGetLocaleInfo(void) {
    NSLocale *locale = [NSLocale currentLocale];
    return @{
        @"identifier": locale.localeIdentifier ?: @"-",
        @"language": [locale objectForKey:NSLocaleLanguageCode] ?: @"-",
        @"country": [locale objectForKey:NSLocaleCountryCode] ?: @"-",
        @"script": [locale objectForKey:NSLocaleScriptCode] ?: @"-",
        @"calendar": [[NSCalendar currentCalendar] calendarIdentifier] ?: @"-",
        @"measurement_system": [[NSLocale currentLocale] objectForKey:NSLocaleMeasurementSystem] ?: @"-",
        @"currency_code": [locale objectForKey:NSLocaleCurrencyCode] ?: @"-",
        @"uses_24h": @([[[NSLocale currentLocale] objectForKey:NSLocaleUsesMetricSystem] boolValue]),
        @"timezone": [[NSTimeZone localTimeZone] name] ?: @"-",
        @"timezone_offset": @([[NSTimeZone localTimeZone] secondsFromGMT]),
    };
}

// ============================================================================
// WiFi / Bluetooth toggles (via private frameworks)
// ============================================================================

static BOOL DTSetWiFi(BOOL enabled) {
    // On jailbroken, use the private MobileWiFi.framework or SBWiFiManager
    void *sbHandle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
    if (sbHandle) {
        // SBSSetWiFiEnabled
        typedef int (*SBSSetWiFiEnableType)(int enabled);
        SBSSetWiFiEnableType SBSSetWiFiEnabled = dlsym(sbHandle, "SBSSetWiFiEnabled");
        if (SBSSetWiFiEnabled) {
            int result = SBSSetWiFiEnabled(enabled ? 1 : 0);
            dlclose(sbHandle);
            return result == 0; // 0 = success in SBS conventions
        }
        dlclose(sbHandle);
    }

    // Fallback: WiFi MIG calls via IOKit
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (iokit) {
        // Could use Apple80211 private framework for fine-grained control
        dlclose(iokit);
    }

    return NO;
}

static BOOL DTSetBluetooth(BOOL enabled) {
    void *sbHandle = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
    if (sbHandle) {
        typedef int (*SBSSetBluetoothEnableType)(int enabled);
        SBSSetBluetoothEnableType SBSSetBluetoothEnabled = dlsym(sbHandle, "SBSSetBluetoothEnabled");
        if (SBSSetBluetoothEnabled) {
            int result = SBSSetBluetoothEnabled(enabled ? 1 : 0);
            dlclose(sbHandle);
            return result == 0;
        }
        dlclose(sbHandle);
    }
    return NO;
}

// ============================================================================
// Auto-lock (display sleep timer)
// ============================================================================

static NSNumber *DTGetAutolock(void) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("SBIdleTimer"),
                                                        CFSTR("com.apple.springboard"));
    if (value) {
        if (CFGetTypeID(value) == CFNumberGetTypeID()) {
            int seconds = 0;
            CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &seconds);
            CFRelease(value);
            return @(seconds);
        }
        CFRelease(value);
    }
    return @60; // Default is 60 seconds
}

static BOOL DTSetAutolock(int seconds) {
    // 0 = Never, -1 = Never, positive = seconds
    CFNumberRef num = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &seconds);
    CFPreferencesSetAppValue(CFSTR("SBIdleTimer"), num, CFSTR("com.apple.springboard"));
    CFPreferencesAppSynchronize(CFSTR("com.apple.springboard"));
    CFRelease(num);

    // Notify SpringBoard
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.apple.springboard.idleTimerChanged"),
                                         NULL, NULL, YES);
    return YES;
}

// ============================================================================
// Developer mode
// ============================================================================

static BOOL DTEnableDevmode(void) {
    // Developer Mode: AMFI / MobileGestalt
    // On jailbroken, we can set this via the amfid or mobilegestalt daemon
    // Simplest: set the DeveloperModeStatus key in mobilegestalt

    void *mgHandle = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
    if (mgHandle) {
        typedef CFTypeRef (*MGCopyAnswerType)(CFStringRef);
        MGCopyAnswerType MGCopyAnswer = dlsym(mgHandle, "MGCopyAnswer");
        if (MGCopyAnswer) {
            // Check current status
            CFStringRef status = MGCopyAnswer(CFSTR("DeveloperModeStatus"));
            if (status && CFEqual(status, CFSTR("1"))) {
                // Already enabled
                if (status) CFRelease(status);
                dlclose(mgHandle);
                return YES;
            }
            if (status) CFRelease(status);
        }
        dlclose(mgHandle);
    }

    // Try toggling via AMFI
    int sbc = sysctlbyname("kern.development", NULL, NULL, NULL, 0);
    if (sbc == 0) {
        int devMode = 1;
        sysctlbyname("security.mac.amfi.developer_mode", NULL, NULL, &devMode, sizeof(devMode));
    }

    // Try SBSRestartRenderServer or respring to apply
    return NO; // Not fully implemented - needs proper SPI
}

static BOOL DTDisableMemlimit(void) {
    // Disable jetsam memory limits for current process
    // Using task_set_phys_footprint_limit from libsystem_kernel
    kern_return_t kr = task_set_phys_footprint_limit(mach_task_self(), 0);
    if (kr == KERN_SUCCESS) return YES;

    // Try via sysctl for processes spawned with posix_spawn
    int noLimit = 1;
    int ret = sysctlbyname("kern.memorystatus_assertion_pid", NULL, NULL, &noLimit, sizeof(noLimit));
    return ret == 0;
}

// ============================================================================
// Configuration profiles
// ============================================================================

static NSArray<NSDictionary *> *DTGetProfiles(void) {
    NSMutableArray *profiles = [NSMutableArray array];

    // MCProfileConnection is private framework
    void *mcHandle = dlopen("/System/Library/PrivateFrameworks/ManagedConfiguration.framework/ManagedConfiguration", RTLD_LAZY);
    if (mcHandle) {
        Class mcProfileConnection = NSClassFromString(@"MCProfileConnection");
        if (mcProfileConnection) {
            id shared = [mcProfileConnection performSelector:NSSelectorFromString(@"sharedConnection")];
            if (shared) {
                // installedProfilesWithFilterClientRestrictions:
                SEL listSel = NSSelectorFromString(@"installedProfilesWithFilterClientRestrictions:");
                BOOL filter = NO;
                NSArray *installed = nil;
                if ([shared respondsToSelector:listSel]) {
                    NSMethodSignature *sig = [shared methodSignatureForSelector:listSel];
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                    [inv setTarget:shared];
                    [inv setSelector:listSel];
                    [inv setArgument:&filter atIndex:2];
                    [inv invoke];
                    __unsafe_unretained id result = nil;
                    [inv getReturnValue:&result];
                    installed = result;
                }

                for (id profile in installed) {
                    SEL idSel = NSSelectorFromString(@"identifier");
                    SEL nameSel = NSSelectorFromString(@"displayName");
                    SEL descSel = NSSelectorFromString(@"profileDescription");
                    SEL installedSel = NSSelectorFromString(@"installDate");
                    SEL removalSel = NSSelectorFromString(@"isLocked");

                    NSString *ident = @"-", *name = @"-", *desc = @"-";
                    id installDate = nil;
                    BOOL locked = NO;

                    if ([profile respondsToSelector:idSel]) ident = [profile performSelector:idSel] ?: @"-";
                    if ([profile respondsToSelector:nameSel]) name = [profile performSelector:nameSel] ?: @"-";
                    if ([profile respondsToSelector:descSel]) desc = [profile performSelector:descSel] ?: @"-";
                    if ([profile respondsToSelector:removalSel]) locked = [[profile performSelector:removalSel] boolValue];
                    if ([profile respondsToSelector:installedSel]) installDate = [profile performSelector:installedSel];

                    [profiles addObject:@{
                        @"identifier": ident,
                        @"display_name": name,
                        @"description": desc,
                        @"locked": @(locked),
                        @"install_date": installDate ?: [NSNull null],
                    }];
                }
            }
        }
        dlclose(mcHandle);
    }

    return profiles;
}

static BOOL DTInstallProfile(NSString *path) {
    void *mcHandle = dlopen("/System/Library/PrivateFrameworks/ManagedConfiguration.framework/ManagedConfiguration", RTLD_LAZY);
    if (mcHandle) {
        Class mcProfileConnection = NSClassFromString(@"MCProfileConnection");
        if (mcProfileConnection) {
            id shared = [mcProfileConnection performSelector:NSSelectorFromString(@"sharedConnection")];
            if (shared) {
                SEL installSel = NSSelectorFromString(@"installProfileData:outError:");
                NSData *data = [NSData dataWithContentsOfFile:path];
                if (data) {
                    NSError *err = nil;
                    NSMethodSignature *sig = [shared methodSignatureForSelector:installSel];
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                    [inv setTarget:shared];
                    [inv setSelector:installSel];
                    [inv setArgument:&data atIndex:2];
                    [inv setArgument:&err atIndex:3];
                    [inv invoke];
                    dlclose(mcHandle);
                    return (err == nil);
                }
            }
        }
        dlclose(mcHandle);
    }
    return NO;
}

static BOOL DTRemoveProfile(NSString *identifier) {
    void *mcHandle = dlopen("/System/Library/PrivateFrameworks/ManagedConfiguration.framework/ManagedConfiguration", RTLD_LAZY);
    if (mcHandle) {
        Class mcProfileConnection = NSClassFromString(@"MCProfileConnection");
        if (mcProfileConnection) {
            id shared = [mcProfileConnection performSelector:NSSelectorFromString(@"sharedConnection")];
            if (shared) {
                SEL removeSel = NSSelectorFromString(@"removeProfileWithIdentifier:");
                if ([shared respondsToSelector:removeSel]) {
                    NSMethodSignature *sig = [shared methodSignatureForSelector:removeSel];
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                    [inv setTarget:shared];
                    [inv setSelector:removeSel];
                    [inv setArgument:&identifier atIndex:2];
                    [inv invoke];
                    dlclose(mcHandle);
                    return YES;
                }
            }
        }
        dlclose(mcHandle);
    }
    return NO;
}

// ============================================================================
// SpringBoard icon layout
// ============================================================================

static NSArray<NSDictionary *> *DTGetIconLayout(void) {
    // Read the IconState.plist from SpringBoard preferences
    NSString *iconStatePath = @"/var/mobile/Library/SpringBoard/IconState.plist";
    NSDictionary *iconState = [NSDictionary dictionaryWithContentsOfFile:iconStatePath];
    if (!iconState) {
        iconStatePath = @"/var/mobile/Library/SpringBoard/DesiredIconState.plist";
        iconState = [NSDictionary dictionaryWithContentsOfFile:iconStatePath];
    }

    if (!iconState) return @[];

    NSMutableArray *pages = [NSMutableArray array];
    NSArray *buttonLists = iconState[@"buttonLists"] ?: iconState[@"iconLists"];
    if (!buttonLists && iconState[@"root"]) {
        buttonLists = iconState[@"root"];
    }

    for (id page in buttonLists) {
        if (![page isKindOfClass:[NSArray class]]) continue;
        NSMutableArray *pageItems = [NSMutableArray array];
        for (id icon in (NSArray *)page) {
            if ([icon isKindOfClass:[NSString class]]) {
                [pageItems addObject:@{@"bundle_id": icon}];
            } else if ([icon isKindOfClass:[NSDictionary class]]) {
                NSString *bundleId = icon[@"bundleIdentifier"] ?: icon[@"displayIdentifier"] ?: @"?";
                [pageItems addObject:@{@"bundle_id": bundleId}];
            }
        }
        if (pageItems.count > 0) {
            [pages addObject:@{@"page": @(pages.count), @"icons": pageItems}];
        }
    }

    return pages;
}

// ============================================================================
// Packet capture (via tcpdump or raw BPF)
// ============================================================================

static pid_t pcapPid = 0;

static BOOL DTStartPcap(NSString *outputPath, int durationSec) {
    if (pcapPid > 0) {
        kill(pcapPid, SIGKILL);
        waitpid(pcapPid, NULL, 0);
        pcapPid = 0;
    }

    // Try tcpdump first (usually available via jailbreak package managers)
    NSArray *paths = @[
        @"/usr/bin/tcpdump",
        @"/usr/sbin/tcpdump",
        @"/usr/local/bin/tcpdump",
        @"/var/jb/usr/bin/tcpdump",
    ];

    NSString *tcpdump = nil;
    for (NSString *p in paths) {
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:p]) {
            tcpdump = p;
            break;
        }
    }

    if (!tcpdump) return NO;

    NSTimeInterval timeout = durationSec > 0 ? durationSec : 30;
    if (timeout > 300) timeout = 300;

    pid_t pid = 0;
    NSArray *args = @[
        tcpdump,
        @"-i", @"en0",
        @"-w", outputPath ?: @"/tmp/ios-mcp-capture.pcap",
        @"-G", @(timeout).stringValue,
        @"-W", @"1",
    ];

    char *argv[args.count + 1];
    for (NSUInteger i = 0; i < args.count; i++) {
        argv[i] = (char *)[args[i] UTF8String];
    }
    argv[args.count] = NULL;

    extern char **environ;
    int ret = posix_spawn(&pid, tcpdump.UTF8String, NULL, NULL, argv, environ);
    if (ret != 0) return NO;

    pcapPid = pid;
    return YES;
}

static BOOL DTStopPcap(void) {
    if (pcapPid <= 0) return NO;

    kill(pcapPid, SIGTERM);
    int status = 0;
    waitpid(pcapPid, &status, WNOHANG);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (pcapPid > 0) {
            kill(pcapPid, SIGKILL);
            waitpid(pcapPid, NULL, 0);
            pcapPid = 0;
        }
    });

    pcapPid = 0;
    return YES;
}

// ============================================================================
// MobileGestalt extended queries
// ============================================================================

static NSDictionary *DTQueryMobileGestalt(NSArray<NSString *> *keys) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];

    void *mgHandle = dlopen("/usr/lib/libMobileGestalt.dylib", RTLD_LAZY);
    if (!mgHandle) return result;

    typedef CFTypeRef (*MGCopyAnswerType)(CFStringRef);
    MGCopyAnswerType MGCopyAnswer = dlsym(mgHandle, "MGCopyAnswer");
    if (!MGCopyAnswer) {
        dlclose(mgHandle);
        return result;
    }

    // Standard keys everyone needs
    NSArray *defaultKeys = keys ?: @[
        @"SerialNumber",
        @"UniqueDeviceID",
        @"DeviceClass",
        @"DeviceColor",
        @"HardwarePlatform",
        @"CPUArchitecture",
        @"DieID",
        @"ProductType",
        @"ProductVersion",
        @"BuildVersion",
        @"DeviceName",
        @"UserAssignedDeviceName",
        @"RegionalBehaviorN88",
        @"BasebandVersion",
        @"FirmwareVersion",
        @"InternationalMobileEquipmentIdentity",
        @"MobileEquipmentIdentifier",
        @"MLBSerialNumber",
        @"ModelNumber",
        @"RegionCode",
        @"SIMTrayStatus",
        @"SoftwareBehavior",
        @"WifiAddress",
        @"BluetoothAddress",
        @"EthernetMacAddress",
        @"ChipID",
        @"SDIOManufacturerTuple",
        @"SDIOProductInfo",
        @"HWModelStr",
        @"BasebandChipId",
        @"BasebandKeyHashInformation",
        @"GreenTea",
        @"HasBaseband",
        @"InternalBuild",
        @"IsSimulator",
        @"PasswordConfigured",
        @"SBAllowSensitiveUI",
        @"Supports2G",
        @"Supports3G",
        @"Supports4G",
        @"Supports5G",
        @"SupportsApplePay",
        @"SupportsPearl",
        @"TelephonyCapability",
        @"DeviceSupportsFaceTime",
        @"HasAllPictureBoosterFeatures",
    ];

    for (NSString *key in defaultKeys) {
        CFTypeRef value = MGCopyAnswer((__bridge CFStringRef)key);
        if (value) {
            if (CFGetTypeID(value) == CFStringGetTypeID()) {
                result[key] = (__bridge NSString *)value;
            } else if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
                result[key] = @(CFBooleanGetValue((CFBooleanRef)value));
            } else if (CFGetTypeID(value) == CFNumberGetTypeID()) {
                result[key] = (__bridge NSNumber *)value;
            } else if (CFGetTypeID(value) == CFDataGetTypeID()) {
                NSData *data = (__bridge NSData *)value;
                result[key] = [data base64EncodedStringWithOptions:0];
            } else {
                result[key] = [NSString stringWithFormat:@"<%@>", (__bridge id)value];
            }
            CFRelease(value);
        }
    }

    dlclose(mgHandle);
    return result;
}

// ============================================================================
// Sysctl system info
// ============================================================================

static NSDictionary *DTGetSysctlInfo(void) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];

    // Thermal state
    int thermal = 0;
    size_t ts = sizeof(thermal);
    if (sysctlbyname("kern.thermal_state_nominal", &thermal, &ts, NULL, 0) == 0) {
        info[@"thermal_nominal"] = @(thermal);
    }

    // Boot time
    struct timeval boottime;
    size_t bt = sizeof(boottime);
    if (sysctlbyname("kern.boottime", &boottime, &bt, NULL, 0) == 0) {
        info[@"boot_time"] = @(boottime.tv_sec);
        info[@"boot_time_iso"] = [[NSString alloc] initWithFormat:@"%ld", (long)boottime.tv_sec];
    }

    // OS release
    char osrelease[256];
    size_t orSize = sizeof(osrelease);
    if (sysctlbyname("kern.osrelease", osrelease, &orSize, NULL, 0) == 0) {
        info[@"os_release"] = [NSString stringWithCString:osrelease encoding:NSUTF8StringEncoding] ?: @"-";
    }

    // Kernel version
    char version[512];
    size_t vSize = sizeof(version);
    if (sysctlbyname("kern.version", version, &vSize, NULL, 0) == 0) {
        info[@"kernel_version"] = [NSString stringWithCString:version encoding:NSUTF8StringEncoding] ?: @"-";
    }

    // Max vnodes
    int maxvnodes = 0;
    size_t mv = sizeof(maxvnodes);
    if (sysctlbyname("kern.maxvnodes", &maxvnodes, &mv, NULL, 0) == 0) {
        info[@"max_vnodes"] = @(maxvnodes);
    }

    // Max processes
    int maxproc = 0;
    size_t mp = sizeof(maxproc);
    if (sysctlbyname("kern.maxproc", &maxproc, &mp, NULL, 0) == 0) {
        info[@"max_processes"] = @(maxproc);
    }

    return info;
}

// ============================================================================
// Disk IO stats
// ============================================================================

static NSDictionary *DTGetDiskIO(void) {
    NSMutableDictionary *io = [NSMutableDictionary dictionary];

    struct statvfs root;
    if (statvfs("/", &root) == 0) {
        io[@"block_size"] = @(root.f_frsize);
        io[@"total_blocks"] = @(root.f_blocks);
        io[@"free_blocks"] = @(root.f_bfree);
        io[@"available_blocks"] = @(root.f_bavail);
        io[@"total_inodes"] = @(root.f_files);
        io[@"free_inodes"] = @(root.f_ffree);
        io[@"mount_from"] = @(root.f_mntfromname);
        io[@"mount_on"] = @(root.f_mntonname);
    }

    return io;
}

// ============================================================================
// MCPServer Category Implementation
// ============================================================================

@implementation MCPServer (GoIOSIntegration)

#pragma mark - System monitoring

- (NSDictionary *)executeGetSysmontap:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    double interval = 1;
    if (!MCPNumberFromArgs(args, @"interval", 1, NO, &interval, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }
    if (interval <= 0) interval = 1;
    if (interval > 60) interval = 60;

    NSMutableDictionary *result = [NSMutableDictionary dictionary];

    // CPU stats
    NSDictionary *cpu = DTGetCPUUsage();
    if (cpu) result[@"cpu"] = cpu;

    // Memory stats
    NSDictionary *mem = DTGetMemoryStats();
    if (mem) result[@"memory"] = mem;

    // Load average
    NSDictionary *load = DTGetLoadAverage();
    if (load) result[@"load"] = load;

    // Process count
    NSArray *procs = DTGetProcessList();
    result[@"process_count"] = @(procs.count);

    // System info
    NSDictionary *sysctl = DTGetSysctlInfo();
    if (sysctl.count > 0) result[@"system"] = sysctl;

    // Disk IO
    NSDictionary *diskIO = DTGetDiskIO();
    if (diskIO.count > 0) result[@"disk_io"] = diskIO;

    // Uptime
    result[@"uptime_seconds"] = @([NSProcessInfo processInfo].systemUptime);
    result[@"timestamp"] = @([[NSDate date] timeIntervalSince1970]);

    return [self mcpSuccess:reqId structuredContent:result];
}

- (NSDictionary *)executeListProcesses:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    NSString *filter = nil;
    double limit = 0;
    if (!MCPStringFromArgs(args, @"filter", NO, &filter, &paramError) ||
        !MCPNumberFromArgs(args, @"limit", 0, NO, &limit, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    NSArray *allProcs = DTGetProcessList();
    NSMutableArray *filtered = [NSMutableArray array];

    for (NSDictionary *p in allProcs) {
        if (filter.length > 0) {
            NSString *name = p[@"name"];
            if (![name.lowercaseString containsString:filter.lowercaseString]) continue;
        }
        [filtered addObject:p];
    }

    if (limit > 0 && filtered.count > limit) {
        filtered = [[filtered subarrayWithRange:NSMakeRange(0, (NSUInteger)limit)] mutableCopy];
    }

    return [self mcpSuccess:reqId structuredContent:@{
        @"processes": filtered,
        @"total": @(allProcs.count),
        @"returned": @(filtered.count),
    }];
}

#pragma mark - Location simulation

- (NSDictionary *)executeSetLocation:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    double lat = 0, lng = 0;
    if (!MCPNumberFromArgs(args, @"latitude", 0, YES, &lat, &paramError) ||
        !MCPNumberFromArgs(args, @"longitude", 0, YES, &lng, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    if (lat < -90 || lat > 90 || lng < -180 || lng > 180) {
        return [self mcpError:reqId code:-32602 message:@"Invalid coordinates: latitude [-90,90], longitude [-180,180]"];
    }

    BOOL ok = DTSimulateLocation(lat, lng);
    if (ok) {
        return [self mcpSuccess:reqId structuredContent:@{
            @"success": @YES,
            @"latitude": @(lat),
            @"longitude": @(lng),
        }];
    }
    return [self mcpSuccess:reqId text:@"Failed to set simulated location. Ensure developer mode is enabled." isError:YES];
}

- (NSDictionary *)executeClearLocation:(id)reqId args:(NSDictionary *)args {
    BOOL ok = DTResetLocation();
    if (ok) {
        return [self mcpSuccess:reqId text:@"Location simulation stopped"];
    }
    return [self mcpSuccess:reqId text:@"Failed to stop location simulation" isError:YES];
}

#pragma mark - Device power control

- (NSDictionary *)executeRebootDevice:(id)reqId args:(NSDictionary *)args {
    // On jailbroken, use reboot or SBSRestartRenderServer
    pid_t pid = 0;
    NSString *rebootBin = @"/sbin/reboot";
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:rebootBin]) {
        rebootBin = @"/var/jb/sbin/reboot";
    }
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:rebootBin]) {
        // Fallback: use FBSSystemService
        void *fbsHandle = dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_LAZY);
        if (fbsHandle) {
            Class fbsService = NSClassFromString(@"FBSSystemService");
            if (fbsService) {
                id shared = [fbsService performSelector:NSSelectorFromString(@"sharedService")];
                SEL rebootSel = NSSelectorFromString(@"reboot");
                if ([shared respondsToSelector:rebootSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                    [shared performSelector:rebootSel];
#pragma clang diagnostic pop
                    dlclose(fbsHandle);
                    return [self mcpSuccess:reqId text:@"Reboot initiated via FBSSystemService"];
                }
            }
            dlclose(fbsHandle);
        }
        return [self mcpSuccess:reqId text:@"Reboot failed: no valid method available" isError:YES];
    }

    char *argv[] = { (char *)rebootBin.UTF8String, NULL };
    extern char **environ;
    int ret = posix_spawn(&pid, rebootBin.UTF8String, NULL, NULL, argv, environ);
    if (ret != 0) {
        return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Reboot failed: %s", strerror(ret)] isError:YES];
    }
    return [self mcpSuccess:reqId text:@"Reboot initiated"];
}

- (NSDictionary *)executeShutdownDevice:(id)reqId args:(NSDictionary *)args {
    // Try FBSSystemService first
    void *fbsHandle = dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_LAZY);
    if (fbsHandle) {
        Class fbsService = NSClassFromString(@"FBSSystemService");
        if (fbsService) {
            id shared = [fbsService performSelector:NSSelectorFromString(@"sharedService")];
            SEL shutdownSel = NSSelectorFromString(@"shutdown");
            if ([shared respondsToSelector:shutdownSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [shared performSelector:shutdownSel];
#pragma clang diagnostic pop
                dlclose(fbsHandle);
                return [self mcpSuccess:reqId text:@"Shutdown initiated via FBSSystemService"];
            }
        }
        dlclose(fbsHandle);
    }

    // Fallback: halt
    pid_t pid = 0;
    char *argv[] = { "/sbin/halt", NULL };
    extern char **environ;
    int ret = posix_spawn(&pid, "/sbin/halt", NULL, NULL, argv, environ);
    if (ret != 0) {
        return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Shutdown failed: %s", strerror(ret)] isError:YES];
    }
    return [self mcpSuccess:reqId text:@"Shutdown initiated"];
}

#pragma mark - Developer features

- (NSDictionary *)executeEnableDevmode:(id)reqId args:(NSDictionary *)args {
    BOOL ok = DTEnableDevmode();
    if (ok) {
        return [self mcpSuccess:reqId text:@"Developer mode enabled"];
    }
    return [self mcpSuccess:reqId text:@"Developer mode toggle not fully supported on this iOS version. Setting was attempted." isError:YES];
}

- (NSDictionary *)executeDisableMemlimit:(id)reqId args:(NSDictionary *)args {
    BOOL ok = DTDisableMemlimit();
    if (ok) {
        return [self mcpSuccess:reqId text:@"Memory limit disabled for current process"];
    }
    return [self mcpSuccess:reqId text:@"Failed to disable memory limit" isError:YES];
}

#pragma mark - Accessibility toggles

- (NSDictionary *)executeAssistiveTouch:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    BOOL enable = NO;
    if (!MCPBoolFromArgs(args, @"enable", YES, &enable, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    BOOL ok = DTSetAssistiveTouch(enable);
    if (ok) {
        return [self mcpSuccess:reqId structuredContent:@{
            @"success": @YES,
            @"assistive_touch": @(enable),
            @"note": @"May require respring to take full effect",
        }];
    }
    return [self mcpSuccess:reqId text:@"Failed to toggle assistive touch" isError:YES];
}

- (NSDictionary *)executeVoiceOver:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    BOOL enable = NO;
    if (!MCPBoolFromArgs(args, @"enable", YES, &enable, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    BOOL ok = DTSetVoiceOver(enable);
    if (ok) {
        return [self mcpSuccess:reqId structuredContent:@{
            @"success": @YES,
            @"voiceover": @(enable),
            @"note": @"May require respring to take full effect",
        }];
    }
    return [self mcpSuccess:reqId text:@"Failed to toggle VoiceOver" isError:YES];
}

- (NSDictionary *)executeZoom:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    BOOL enable = NO;
    if (!MCPBoolFromArgs(args, @"enable", YES, &enable, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    BOOL ok = DTSetZoom(enable);
    if (ok) {
        return [self mcpSuccess:reqId structuredContent:@{
            @"success": @YES,
            @"zoom": @(enable),
            @"note": @"May require respring to take full effect",
        }];
    }
    return [self mcpSuccess:reqId text:@"Failed to toggle Zoom" isError:YES];
}

#pragma mark - Language & Region

- (NSDictionary *)executeSetLanguage:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    NSString *lang = nil;
    if (!MCPStringFromArgs(args, @"language", YES, &lang, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    BOOL ok = DTSetLanguage(lang);
    if (ok) {
        return [self mcpSuccess:reqId structuredContent:@{
            @"success": @YES,
            @"language": lang,
            @"note": @"Requires respring or reboot to fully apply",
        }];
    }
    return [self mcpSuccess:reqId text:@"Failed to set language" isError:YES];
}

- (NSDictionary *)executeSetLocale:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    NSString *localeId = nil;
    if (!MCPStringFromArgs(args, @"locale", YES, &localeId, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    BOOL ok = DTSetLocale(localeId);
    if (ok) {
        return [self mcpSuccess:reqId structuredContent:@{
            @"success": @YES,
            @"locale": localeId,
            @"note": @"Requires respring or reboot to fully apply",
        }];
    }
    return [self mcpSuccess:reqId text:@"Failed to set locale" isError:YES];
}

#pragma mark - Network controls

- (NSDictionary *)executeGetNetworkInfo:(id)reqId args:(NSDictionary *)args {
    NSDictionary *info = DTGetNetworkInfo();
    NSDictionary *locale = DTGetLocaleInfo();

    NSMutableDictionary *result = [info mutableCopy] ?: [NSMutableDictionary dictionary];
    [result addEntriesFromDictionary:locale];

    return [self mcpSuccess:reqId structuredContent:result];
}

- (NSDictionary *)executeEnableWifi:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    BOOL enable = NO;
    if (!MCPBoolFromArgs(args, @"enable", YES, &enable, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    BOOL ok = DTSetWiFi(enable);
    if (ok) {
        return [self mcpSuccess:reqId structuredContent:@{
            @"success": @YES,
            @"wifi": @(enable),
        }];
    }
    return [self mcpSuccess:reqId text:@"Failed to toggle WiFi. Private framework may not be available." isError:YES];
}

- (NSDictionary *)executeEnableBluetooth:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    BOOL enable = NO;
    if (!MCPBoolFromArgs(args, @"enable", YES, &enable, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    BOOL ok = DTSetBluetooth(enable);
    if (ok) {
        return [self mcpSuccess:reqId structuredContent:@{
            @"success": @YES,
            @"bluetooth": @(enable),
        }];
    }
    return [self mcpSuccess:reqId text:@"Failed to toggle Bluetooth. Private framework may not be available." isError:YES];
}

#pragma mark - Configuration profiles

- (NSDictionary *)executeGetProfiles:(id)reqId args:(NSDictionary *)args {
    NSArray *profiles = DTGetProfiles();
    return [self mcpSuccess:reqId structuredContent:@{
        @"profiles": profiles,
        @"count": @(profiles.count),
    }];
}

- (NSDictionary *)executeInstallProfile:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    NSString *path = nil;
    if (!MCPStringFromArgs(args, @"path", YES, &path, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Profile file not found: %@", path] isError:YES];
    }

    BOOL ok = DTInstallProfile(path);
    if (ok) {
        return [self mcpSuccess:reqId structuredContent:@{
            @"success": @YES,
            @"path": path,
        }];
    }
    return [self mcpSuccess:reqId text:@"Failed to install profile" isError:YES];
}

- (NSDictionary *)executeRemoveProfile:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    NSString *identifier = nil;
    if (!MCPStringFromArgs(args, @"identifier", YES, &identifier, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    BOOL ok = DTRemoveProfile(identifier);
    if (ok) {
        return [self mcpSuccess:reqId structuredContent:@{
            @"success": @YES,
            @"identifier": identifier,
        }];
    }
    return [self mcpSuccess:reqId text:@"Failed to remove profile" isError:YES];
}

#pragma mark - SpringBoard icons

- (NSDictionary *)executeSpringboardIcons:(id)reqId args:(NSDictionary *)args {
    NSArray *pages = DTGetIconLayout();
    return [self mcpSuccess:reqId structuredContent:@{
        @"pages": pages,
        @"page_count": @(pages.count),
    }];
}

#pragma mark - Packet capture

- (NSDictionary *)executePcapStart:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    NSString *path = nil;
    double duration = 30;
    if (!MCPStringFromArgs(args, @"path", NO, &path, &paramError) ||
        !MCPNumberFromArgs(args, @"duration", 30, NO, &duration, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }
    if (!path.length) path = @"/tmp/ios-mcp-capture.pcap";

    BOOL ok = DTStartPcap(path, (int)duration);
    if (ok) {
        return [self mcpSuccess:reqId structuredContent:@{
            @"success": @YES,
            @"output": path,
            @"duration_seconds": @(duration),
            @"pid": @(pcapPid),
        }];
    }
    return [self mcpSuccess:reqId text:@"Failed to start packet capture. tcpdump may not be installed." isError:YES];
}

- (NSDictionary *)executePcapStop:(id)reqId args:(NSDictionary *)args {
    if (pcapPid <= 0) {
        return [self mcpSuccess:reqId text:@"No active packet capture" isError:YES];
    }

    BOOL ok = DTStopPcap();
    if (ok) {
        return [self mcpSuccess:reqId structuredContent:@{
            @"success": @YES,
            @"was_pid": @(pcapPid),
            @"output": @"/tmp/ios-mcp-capture.pcap",
        }];
    }
    return [self mcpSuccess:reqId text:@"Failed to stop packet capture" isError:YES];
}

#pragma mark - Auto-lock

- (NSDictionary *)executeGetAutolock:(id)reqId args:(NSDictionary *)args {
    NSNumber *seconds = DTGetAutolock();
    return [self mcpSuccess:reqId structuredContent:@{
        @"autolock_seconds": seconds,
    }];
}

- (NSDictionary *)executeSetAutolock:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    double seconds = 60;
    if (!MCPNumberFromArgs(args, @"seconds", 60, YES, &seconds, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    BOOL ok = DTSetAutolock((int)seconds);
    if (ok) {
        return [self mcpSuccess:reqId structuredContent:@{
            @"success": @YES,
            @"autolock_seconds": @((int)seconds),
            @"note": @"0 or -1 = Never auto-lock. Positive = seconds before auto-lock.",
        }];
    }
    return [self mcpSuccess:reqId text:@"Failed to set auto-lock" isError:YES];
}

#pragma mark - Extended device info (MobileGestalt)

- (NSDictionary *)executeMobilegestalt:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;

    // Optional specific keys
    NSArray *keys = nil;
    id keysValue = args[@"keys"];
    if (keysValue && [keysValue isKindOfClass:[NSArray class]]) {
        keys = keysValue;
    }

    NSDictionary *gestalt = DTQueryMobileGestalt(keys);

    // Include locale info for convenience
    NSMutableDictionary *result = [gestalt mutableCopy];
    result[@"locale"] = DTGetLocaleInfo();
    result[@"network"] = DTGetNetworkInfo();

    return [self mcpSuccess:reqId structuredContent:result];
}

@end
