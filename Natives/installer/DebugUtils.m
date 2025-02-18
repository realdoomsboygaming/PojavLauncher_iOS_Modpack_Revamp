#import "DebugUtils.h"

static NSString *const kDebugLogFilePath = @"modpack_debug.log";
static NSString *const kDebugLogDirectory = @"DebugLogs";
static BOOL kDebugLoggingEnabled = YES;

@implementation DebugUtils

+ (void)initializeDebugLogging {
    if (!kDebugLoggingEnabled) return;
    
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    NSString *logDirectory = [documentsDirectory stringByAppendingPathComponent:kDebugLogDirectory];
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:logDirectory]) {
        [fileManager createDirectoryAtPath:logDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    }
    
    NSString *logFilePath = [logDirectory stringByAppendingPathComponent:kDebugLogFilePath];
    if (![fileManager fileExistsAtPath:logFilePath]) {
        [fileManager createFileAtPath:logFilePath contents:nil attributes:nil];
    }
}

+ (void)log:(NSString *)message {
    [self logWithLevel:@"DEBUG" message:message];
}

+ (void)logWithLevel:(NSString *)level message:(NSString *)message {
    if (!kDebugLoggingEnabled) return;
    
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    NSString *logFilePath = [documentsDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"%@/%@", kDebugLogDirectory, kDebugLogFilePath]];
    
    NSDateFormatter *dateFormatter = [[NSDateFormatter alloc] init];
    [dateFormatter setDateFormat:@"yyyy-MM-dd HH:mm:ss.SSS"];
    NSString *timestamp = [dateFormatter stringFromDate:[NSDate date]];
    
    NSString *logMessage = [NSString stringWithFormat:@"%@ [%@] %@", timestamp, level, message];
    
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logFilePath];
    [fileHandle seekToEndOfFile];
    [fileHandle writeData:[logMessage dataUsingEncoding:NSUTF8StringEncoding]];
    [fileHandle writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [fileHandle closeFile];
}

@end
