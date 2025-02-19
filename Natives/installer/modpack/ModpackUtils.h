#import <Foundation/Foundation.h>
#import "UnzipKit.h"

@interface ModpackUtils : NSObject

/// Extract a directory named `dir` from the UZKArchive into the file system
+ (void)archive:(UZKArchive *)archive
extractDirectory:(NSString *)dir
         toPath:(NSString *)path
          error:(NSError **)error;

/// Produce a dictionary with "id" (and optional "json") for the given dependencies
+ (NSDictionary *)infoForDependencies:(NSDictionary *)dependency;

@end
