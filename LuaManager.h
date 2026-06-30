#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LuaManager : NSObject

+ (instancetype)sharedInstance;

/// Execute a raw LUA script string. Returns a dictionary with keys:
///   @"success"  : BOOL
///   @"result"   : id (NSString / NSDictionary / NSArray / NSNumber)
///   @"error"    : NSString (if success=NO)
///   @"output"   : NSString (print() output captured during execution)
- (NSDictionary *)executeScript:(NSString *)script;

/// Script storage directory (persistent across resprings)
@property (nonatomic, readonly) NSString *scriptsDirectory;

/// List all saved .lua scripts in the scripts directory
- (NSArray<NSString *> *)listScripts;

/// Read a saved script's content
- (nullable NSString *)readScriptNamed:(NSString *)name;

/// Save (overwrite) a script
- (BOOL)saveScript:(NSString *)script named:(NSString *)name error:(NSError **)error;

/// Delete a saved script
- (BOOL)deleteScriptNamed:(NSString *)name error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
