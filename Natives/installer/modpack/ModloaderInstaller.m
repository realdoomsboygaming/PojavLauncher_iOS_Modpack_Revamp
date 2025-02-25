#import "ModloaderInstaller.h"
#import "CurseForgeAPI.h"
#import "/installer/FabricInstallViewController.h"
#import <UIKit/UIKit.h>

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

+ (void)performModloaderInstallationForModpackDirectory:(NSString *)modpackDirectory
                                   fromViewController:(UIViewController *)vc {
    NSError *error = nil;
    NSDictionary *installerInfo = [self readInstallerInfoFromModpackDirectory:modpackDirectory error:&error];
    if (!installerInfo) {
        NSLog(@"[ModloaderInstaller] Error reading installer info: %@", error.localizedDescription);
        return;
    }
    
    if ([installerInfo[@"installOnFirstLaunch"] boolValue]) {
        NSString *loaderType = installerInfo[@"loaderType"];
        if ([loaderType isEqualToString:@"forge"]) {
            NSString *versionString = installerInfo[@"versionString"];
            NSArray *components = [versionString componentsSeparatedByString:@"-forge-"];
            if (components.count == 2) {
                NSString *vanillaVer = components[0];
                NSString *forgeVer = components[1];
                NSString *apiKey = [[NSUserDefaults standardUserDefaults] stringForKey:@"CURSEFORGE_API_KEY"];
                if (apiKey) {
                    CurseForgeAPI *cfAPI = [[CurseForgeAPI alloc] initWithAPIKey:apiKey];
                    [cfAPI autoInstallForge:vanillaVer loaderVersion:forgeVer];
                } else {
                    NSLog(@"No CurseForge API key available for automatic Forge installation.");
                }
            } else {
                NSLog(@"[ModloaderInstaller] Unable to parse version string: %@", versionString);
            }
        } else if ([loaderType isEqualToString:@"fabric"]) {
            // Present the FabricInstallViewController to handle the installation UI/process.
            FabricInstallViewController *fabricVC = [FabricInstallViewController new];
            [vc presentViewController:fabricVC animated:YES completion:nil];
        }
        
        // Remove installer file after processing.
        NSString *installerPath = [modpackDirectory stringByAppendingPathComponent:@"modloader_installer.json"];
        NSError *removeError = nil;
        if (![[NSFileManager defaultManager] removeItemAtPath:installerPath error:&removeError]) {
            NSLog(@"[ModloaderInstaller] Failed to remove installer file: %@", removeError.localizedDescription);
        }
    }
}

@end
