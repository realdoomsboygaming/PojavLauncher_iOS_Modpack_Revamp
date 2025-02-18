#import <Foundation/Foundation.h>

@interface DebugUtils : NSObject

+ (void)initializeDebugLogging;
+ (void)log:(NSString *)message;
+ (void)logWithLevel:(NSString *)level message:(NSString *)message;

@end
