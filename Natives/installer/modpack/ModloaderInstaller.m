#import "ModloaderInstaller.h"

@implementation ModloaderInstaller

+ (BOOL)createInstallerFileInModpackDirectory:(NSString *)modpackDirectory
                             withVersionString:(NSString *)versionString
                                   loaderType:(NSString *)loaderType
                                        error:(NSError **)error {
    if (!modpackDirectory.length || !versionString.length || !loaderType.length) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModloaderInstallerErrorDomain"
                                         code:100
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid parameters"}];
        }
        return NO;
    }
    
    // Build a dictionary that indicates which mod loader should be installed.
    NSDictionary *installerInfo = @{
        @"loaderType": loaderType,
        @"versionString": versionString,
        @"installOnFirstLaunch": @YES
    };
    
    NSError *jsonError = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:installerInfo options:NSJSONWritingPrettyPrinted error:&jsonError];
    if (!jsonData) {
        if (error) {
            *error = jsonError;
        }
        return NO;
    }
    
    // Save the file as "modloader_installer.json" within the modpack folder.
    NSString *filePath = [modpackDirectory stringByAppendingPathComponent:@"modloader_installer.json"];
    BOOL success = [jsonData writeToFile:filePath options:NSDataWritingAtomic error:&jsonError];
    if (!success && error) {
        *error = jsonError;
    }
    return success;
}

+ (nullable NSDictionary *)readInstallerInfoFromModpackDirectory:(NSString *)modpackDirectory error:(NSError **)error {
    if (!modpackDirectory.length) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModloaderInstallerErrorDomain"
                                         code:101
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid modpack directory"}];
        }
        return nil;
    }
    
    NSString *filePath = [modpackDirectory stringByAppendingPathComponent:@"modloader_installer.json"];
    NSData *jsonData = [NSData dataWithContentsOfFile:filePath options:0 error:error];
    if (!jsonData) {
        return nil;
    }
    
    NSDictionary *installerInfo = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:error];
    if (![installerInfo isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModloaderInstallerErrorDomain"
                                         code:102
                                     userInfo:@{NSLocalizedDescriptionKey: @"Invalid installer file format"}];
        }
        return nil;
    }
    return installerInfo;
}

@end
