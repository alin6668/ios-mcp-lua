// MCPServerInternal.h — Shared internal declarations for MCPServer.m and its categories
// These functions are originally defined in MCPServer.m

#import <Foundation/Foundation.h>

@class MCPServer;

// Parameter parsing helpers (formerly static in MCPServer.m)
BOOL MCPNumberFromArgs(NSDictionary *args, NSString *key, double defaultValue, BOOL required, double *outValue, NSString **outError);
BOOL MCPDoubleFromValue(id value, NSString *parameterName, double *outValue, NSString **outError);
BOOL MCPStringFromArgs(NSDictionary *args, NSString *key, BOOL required, NSString **outValue, NSString **outError);
BOOL MCPBoolFromArgs(NSDictionary *args, NSString *key, BOOL defaultValue, BOOL *outValue, NSString **outError);

// Lock guard
BOOL MCPLockGuardToolAllowed(NSString *toolName);

// Response builders (accessible to categories)
@interface MCPServer (InternalResponseBuilders)
- (NSDictionary *)mcpSuccess:(id)reqId text:(NSString *)text;
- (NSDictionary *)mcpSuccess:(id)reqId text:(NSString *)text isError:(BOOL)isError;
- (NSDictionary *)mcpSuccess:(id)reqId structuredContent:(NSDictionary *)structuredContent;
- (NSDictionary *)mcpSuccess:(id)reqId structuredContent:(NSDictionary *)structuredContent isError:(BOOL)isError;
- (NSDictionary *)mcpSuccess:(id)reqId text:(NSString *)text structuredContent:(NSDictionary *)structuredContent isError:(BOOL)isError;
- (NSDictionary *)mcpError:(id)reqId code:(NSInteger)code message:(NSString *)message;
@end
