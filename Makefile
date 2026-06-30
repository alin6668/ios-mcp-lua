# Rootful: iOS 13.0+, Rootless: iOS 15.0+, Roothide: iOS 15.0+
ARCHS = arm64 arm64e
ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
    TARGET := iphone:clang:latest:15.0
else ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
    TARGET := iphone:clang:latest:15.0
else
    TARGET := iphone:clang:latest:13.0
endif

# Lua 5.4.7 embedded C sources (exclude standalone lua.c and luac.c)
LUASRC = third_party/lua/lua-5.4.7/src/lapi.c \
         third_party/lua/lua-5.4.7/src/lauxlib.c \
         third_party/lua/lua-5.4.7/src/lbaselib.c \
         third_party/lua/lua-5.4.7/src/lcode.c \
         third_party/lua/lua-5.4.7/src/lcorolib.c \
         third_party/lua/lua-5.4.7/src/lctype.c \
         third_party/lua/lua-5.4.7/src/ldblib.c \
         third_party/lua/lua-5.4.7/src/ldebug.c \
         third_party/lua/lua-5.4.7/src/ldo.c \
         third_party/lua/lua-5.4.7/src/ldump.c \
         third_party/lua/lua-5.4.7/src/lfunc.c \
         third_party/lua/lua-5.4.7/src/lgc.c \
         third_party/lua/lua-5.4.7/src/linit.c \
         third_party/lua/lua-5.4.7/src/liolib.c \
         third_party/lua/lua-5.4.7/src/llex.c \
         third_party/lua/lua-5.4.7/src/lmathlib.c \
         third_party/lua/lua-5.4.7/src/lmem.c \
         third_party/lua/lua-5.4.7/src/loadlib.c \
         third_party/lua/lua-5.4.7/src/lobject.c \
         third_party/lua/lua-5.4.7/src/lopcodes.c \
         third_party/lua/lua-5.4.7/src/loslib.c \
         third_party/lua/lua-5.4.7/src/lparser.c \
         third_party/lua/lua-5.4.7/src/lstate.c \
         third_party/lua/lua-5.4.7/src/lstring.c \
         third_party/lua/lua-5.4.7/src/lstrlib.c \
         third_party/lua/lua-5.4.7/src/ltable.c \
         third_party/lua/lua-5.4.7/src/ltablib.c \
         third_party/lua/lua-5.4.7/src/ltm.c \
         third_party/lua/lua-5.4.7/src/lundump.c \
         third_party/lua/lua-5.4.7/src/lutf8lib.c \
         third_party/lua/lua-5.4.7/src/lvm.c \
         third_party/lua/lua-5.4.7/src/lzio.c

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ios-mcp
BUNDLE_NAME = iosmcpprefs

ios-mcp_FILES = Tweak.x MCPServer.m MCPGoIOSIntegration.m MCPLogger.m HIDManager.m ScreenManager.m ClipboardManager.m AppManager.m AccessibilityManager.m TextInputManager.m FileSystemManager.m LogManager.m OCRManager.m MCPProcessUtil.m MCPAXQueryContext.m MCPAXRemoteContextResolver.m MCPUIElementSerializer.m MCPUIElementsFacade.m MCPAXAttributeBridge.m MCPAXNodeSource.m LuaManager.m $(LUASRC)
ios-mcp_CFLAGS = -fobjc-arc -Wno-unused-function -Wno-deprecated-declarations -I$(THEOS_PROJECT_DIR)/third_party/lua/lua-5.4.7/src -DLUA_USE_IOS
ios-mcp_FRAMEWORKS = IOKit UIKit CoreGraphics QuartzCore MobileCoreServices AVFoundation Security Vision

ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
    ios-mcp_LIBRARIES = roothide
    ios-mcp_CFLAGS += -DMCP_ROOTHIDE=1
    iosmcpprefs_LIBRARIES = roothide
else ifeq ($(THEOS_PACKAGE_SCHEME),rootless)
    ios-mcp_CFLAGS += -DMCP_ROOTLESS=1
endif

iosmcpprefs_FILES = prefs/IOSMCPRootListController.m prefs/IOSMCPQRCodeCell.m MCPLogger.m
iosmcpprefs_CFLAGS = -fobjc-arc
iosmcpprefs_FRAMEWORKS = UIKit CoreGraphics
iosmcpprefs_PRIVATE_FRAMEWORKS = Preferences
iosmcpprefs_INSTALL_PATH = /Library/PreferenceBundles
iosmcpprefs_RESOURCE_DIRS = prefs/Resources

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/bundle.mk

after-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences"$(ECHO_END)
	$(ECHO_NOTHING)cp prefs/entry/ios-mcp.plist "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/ios-mcp.plist"$(ECHO_END)
	@# Bundle license and third-party notices for binary redistribution
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/usr/share/doc/ios-mcp"$(ECHO_END)
	$(ECHO_NOTHING)cp LICENSE "$(THEOS_STAGING_DIR)/usr/share/doc/ios-mcp/LICENSE" 2>/dev/null || true$(ECHO_END)
	$(ECHO_NOTHING)cp NOTICE "$(THEOS_STAGING_DIR)/usr/share/doc/ios-mcp/NOTICE" 2>/dev/null || true$(ECHO_END)
	$(ECHO_NOTHING)cp THIRD_PARTY_NOTICES.md "$(THEOS_STAGING_DIR)/usr/share/doc/ios-mcp/THIRD_PARTY_NOTICES.md" 2>/dev/null || true$(ECHO_END)
	$(ECHO_NOTHING)cp AppSync/LICENSE "$(THEOS_STAGING_DIR)/usr/share/doc/ios-mcp/GPL-3.0-AppSync.txt" 2>/dev/null || true$(ECHO_END)
	$(ECHO_NOTHING)cp third_party/ldid/COPYING "$(THEOS_STAGING_DIR)/usr/share/doc/ios-mcp/AGPL-3.0-ldid.txt" 2>/dev/null || true$(ECHO_END)
	@# Bundle mcp-appsync (bypass installd signature checks) - skip if not built
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries"$(ECHO_END)
	$(ECHO_NOTHING)[ -f "AppSync/.theos/obj/mcp-appsync-installd.dylib" ] && cp AppSync/.theos/obj/mcp-appsync-installd.dylib "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/mcp-appsync-installd.dylib" || echo "  SKIP: mcp-appsync-installd.dylib not built"$(ECHO_END)
	$(ECHO_NOTHING)cp AppSync/AppSyncUnified-installd/mcp-appsync-installd.plist "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/mcp-appsync-installd.plist" 2>/dev/null || true$(ECHO_END)
	$(ECHO_NOTHING)[ -f "AppSync/.theos/obj/mcp-appsync-frontboard.dylib" ] && cp AppSync/.theos/obj/mcp-appsync-frontboard.dylib "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/mcp-appsync-frontboard.dylib" || echo "  SKIP: mcp-appsync-frontboard.dylib not built"$(ECHO_END)
	$(ECHO_NOTHING)cp AppSync/AppSyncUnified-FrontBoard/mcp-appsync-frontboard.plist "$(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/mcp-appsync-frontboard.plist" 2>/dev/null || true$(ECHO_END)
	@# Bundle mcp-appinst (CLI IPA installer) - skip if not built
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/usr/bin"$(ECHO_END)
	$(ECHO_NOTHING)[ -f "AppSync/appinst/.theos/obj/mcp-appinst" ] && cp AppSync/appinst/.theos/obj/mcp-appinst "$(THEOS_STAGING_DIR)/usr/bin/mcp-appinst" || echo "  SKIP: mcp-appinst not built"$(ECHO_END)
	@# Bundle mcp-roothelper (CLI TrollStore RootHelper wrapper) - skip if not built
	$(ECHO_NOTHING)[ -f "mcp-roothelper/.theos/obj/mcp-roothelper" ] && cp mcp-roothelper/.theos/obj/mcp-roothelper "$(THEOS_STAGING_DIR)/usr/bin/mcp-roothelper" || echo "  SKIP: mcp-roothelper not built"$(ECHO_END)
	@# Bundle mcp-ldid (CLI fakesign helper) - skip if not built
	$(ECHO_NOTHING)[ -f "mcp-ldid/.theos/obj/mcp-ldid" ] && cp mcp-ldid/.theos/obj/mcp-ldid "$(THEOS_STAGING_DIR)/usr/bin/mcp-ldid" || echo "  SKIP: mcp-ldid not built"$(ECHO_END)
	@# Bundle mcp-root (setuid root helper) - skip if not built
	$(ECHO_NOTHING)[ -f "mcp-root/.theos/obj/mcp-root" ] && cp mcp-root/.theos/obj/mcp-root "$(THEOS_STAGING_DIR)/usr/bin/mcp-root" && chmod 4755 "$(THEOS_STAGING_DIR)/usr/bin/mcp-root" || echo "  SKIP: mcp-root not built"$(ECHO_END)
	@# Bundle mcp-logreader (unified system log reader) - skip if not built
	$(ECHO_NOTHING)[ -f "mcp-logreader/.theos/obj/mcp-logreader" ] && cp mcp-logreader/.theos/obj/mcp-logreader "$(THEOS_STAGING_DIR)/usr/bin/mcp-logreader" || echo "  SKIP: mcp-logreader not built"$(ECHO_END)
	@# Bundle LUA scripts for ios-mcp scripting
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/var/mobile/Documents/ios-mcp/scripts"$(ECHO_END)
	$(ECHO_NOTHING)if [ -d luascripts ]; then cp luascripts/*.lua "$(THEOS_STAGING_DIR)/var/mobile/Documents/ios-mcp/scripts/" 2>/dev/null || true; fi$(ECHO_END)

after-install::
	install.exec "killall -9 SpringBoard"
