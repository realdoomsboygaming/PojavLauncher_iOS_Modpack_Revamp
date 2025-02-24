#import <Foundation/Foundation.h>
#import "UnzipKit.h"

@interface ModpackUtils : NSObject

+ (void)archive:(UZKArchive *)archive extractDirectory:(NSString *)dir toPath:(NSString *)path error:(NSError **)error;
+ (NSDictionary *)infoForDependencies:(NSDictionary *)dependency;

+ (void)extractArchiveAtPath:(NSString *)archivePath toDestination:(NSString *)destPath completion:(void (^)(NSError *error))completion;

@end
