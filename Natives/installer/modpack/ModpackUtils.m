#import "installer/FabricUtils.h"
#import "ModpackUtils.h"

@implementation ModpackUtils

+ (void)archive:(UZKArchive *)archive
extractDirectory:(NSString *)dir
         toPath:(NSString *)path
          error:(NSError *__autoreleasing*)error
{
    [archive performOnFilesInArchive:^(UZKFileInfo *fileInfo, BOOL *stop) {
        // Only extract if file is in the requested subdirectory
        if (![fileInfo.filename hasPrefix:dir] || fileInfo.filename.length <= dir.length) {
            return;
        }
        
        // Destination path
        NSString *fileName = [fileInfo.filename substringFromIndex:dir.length + 1];
        NSString *destItemPath = [path stringByAppendingPathComponent:fileName];
        
        // Create directory if needed
        NSString *destDirPath = fileInfo.isDirectory
                                ? destItemPath
                                : destItemPath.stringByDeletingLastPathComponent;
        BOOL createdDir = [NSFileManager.defaultManager
            createDirectoryAtPath:destDirPath
      withIntermediateDirectories:YES
                       attributes:nil
                            error:error];
        if (!createdDir) {
            *stop = YES;
            return;
        } else if (fileInfo.isDirectory) {
            return;
        }
        
        // Extract data
        NSData *data = [archive extractData:fileInfo error:error];
        if (!data || *error) {
            *stop = YES;
            return;
        }
        
        BOOL written = [data writeToFile:destItemPath
                                 options:NSDataWritingAtomic
                                   error:error];
        *stop = !data || !written;
        if (!*stop) {
            NSLog(@"[ModpackUtils] Extracted %@", fileInfo.filename);
        }
    } error:error];
}

+ (NSDictionary *)infoForDependencies:(NSDictionary *)dependency {
    if (![dependency isKindOfClass:[NSDictionary class]]) {
        return @{};
    }
    
    NSMutableDictionary *info = [NSMutableDictionary new];
    NSString *minecraftVersion = dependency[@"minecraft"];
    if (!minecraftVersion) {
        return @{};
    }
    
    if (dependency[@"forge"]) {
        info[@"id"] = [NSString stringWithFormat:@"%@-forge-%@", minecraftVersion, dependency[@"forge"]];
    } else if (dependency[@"fabric-loader"]) {
        info[@"id"] = [NSString stringWithFormat:@"fabric-loader-%@-%@", dependency[@"fabric-loader"], minecraftVersion];
        info[@"json"] = [NSString stringWithFormat:FabricUtils.endpoints[@"Fabric"][@"json"],
                         minecraftVersion, dependency[@"fabric-loader"]];
    } else if (dependency[@"quilt-loader"]) {
        info[@"id"] = [NSString stringWithFormat:@"quilt-loader-%@-%@", dependency[@"quilt-loader"], minecraftVersion];
        info[@"json"] = [NSString stringWithFormat:FabricUtils.endpoints[@"Quilt"][@"json"],
                         minecraftVersion, dependency[@"quilt-loader"]];
    }
    return info;
}

@end
