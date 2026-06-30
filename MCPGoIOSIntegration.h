#import <Foundation/Foundation.h>

@interface MCPServer (GoIOSIntegration)

// System monitoring
- (NSDictionary *)executeGetSysmontap:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeListProcesses:(id)reqId args:(NSDictionary *)args;

// Location simulation
- (NSDictionary *)executeSetLocation:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeClearLocation:(id)reqId args:(NSDictionary *)args;

// Device power control
- (NSDictionary *)executeRebootDevice:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeShutdownDevice:(id)reqId args:(NSDictionary *)args;

// Developer features
- (NSDictionary *)executeEnableDevmode:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeDisableMemlimit:(id)reqId args:(NSDictionary *)args;

// Accessibility toggles
- (NSDictionary *)executeAssistiveTouch:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeVoiceOver:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeZoom:(id)reqId args:(NSDictionary *)args;

// Language & Region
- (NSDictionary *)executeSetLanguage:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeSetLocale:(id)reqId args:(NSDictionary *)args;

// Network controls
- (NSDictionary *)executeGetNetworkInfo:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeEnableWifi:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeEnableBluetooth:(id)reqId args:(NSDictionary *)args;

// Configuration profiles
- (NSDictionary *)executeGetProfiles:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeInstallProfile:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeRemoveProfile:(id)reqId args:(NSDictionary *)args;

// SpringBoard icons
- (NSDictionary *)executeSpringboardIcons:(id)reqId args:(NSDictionary *)args;

// Packet capture
- (NSDictionary *)executePcapStart:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executePcapStop:(id)reqId args:(NSDictionary *)args;

// Auto-lock
- (NSDictionary *)executeGetAutolock:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeSetAutolock:(id)reqId args:(NSDictionary *)args;

// Extended device info (MobileGestalt)
- (NSDictionary *)executeMobilegestalt:(id)reqId args:(NSDictionary *)args;

@end
