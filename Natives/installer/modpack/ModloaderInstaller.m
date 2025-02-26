#import "ModloaderInstaller.h"
#import "CurseForgeAPI.h"
#import "installer/FabricInstallViewController.h"
#import "LauncherNavigationController.h"   
#import "JavaGUIViewController.h"           
#import "AFNetworking.h"                   
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
            // Parse Forge version (expected format: "<MCVersion>-forge-<ForgeVersion>")
            NSString *versionString = installerInfo[@"versionString"];
            NSArray *components = [versionString componentsSeparatedByString:@"-forge-"];
            if (components.count == 2) {
                NSString *vanillaVer = components[0];
                NSString *forgeVer   = components[1];
                NSString *combinedVer = [NSString stringWithFormat:@"%@-%@", vanillaVer, forgeVer];
                // Construct the official Forge installer URL from Maven repository
                NSString *forgeURL = [NSString stringWithFormat:@"https://maven.minecraftforge.net/net/minecraftforge/forge/%@/forge-%@-installer.jar", combinedVer, combinedVer];
                NSString *outPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"forge-installer.jar"];
                // Remove any existing file
                [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    NSData *jarData = [NSData dataWithContentsOfURL:[NSURL URLWithString:forgeURL]];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (!jarData) {
                            NSLog(@"[ModloaderInstaller] Failed to download Forge installer from %@", forgeURL);
                        } else {
                            [jarData writeToFile:outPath atomically:YES];
                            NSLog(@"[ModloaderInstaller] Forge installer downloaded to %@", outPath);
                            // Try to obtain a LauncherNavigationController from vc to call enterModInstallerWithPath:
                            if ([vc isKindOfClass:[LauncherNavigationController class]]) {
                                LauncherNavigationController *navVC = (LauncherNavigationController *)vc;
                                [navVC enterModInstallerWithPath:outPath hitEnterAfterWindowShown:YES];
                            } else if (vc.navigationController && [vc.navigationController isKindOfClass:[LauncherNavigationController class]]) {
                                LauncherNavigationController *navVC = (LauncherNavigationController *)vc.navigationController;
                                [navVC enterModInstallerWithPath:outPath hitEnterAfterWindowShown:YES];
                            } else {
                                // Fallback: Present the Java GUI installer directly.
                                JavaGUIViewController *installerVC = [[JavaGUIViewController alloc] init];
                                installerVC.filepath = outPath;
                                installerVC.hitEnterAfterWindowShown = YES;
                                if (!installerVC.requiredJavaVersion) {
                                    NSLog(@"[ModloaderInstaller] Java runtime not available. Cannot run Forge installer.");
                                } else {
                                    installerVC.modalPresentationStyle = UIModalPresentationFullScreen;
                                    NSLog(@"[ModloaderInstaller] Launching Forge installer UI...");
                                    [vc presentViewController:installerVC animated:YES completion:nil];
                                }
                            }
                        }
                    });
                });
            } else {
                NSLog(@"[ModloaderInstaller] Unable to parse version string: %@", versionString);
            }
        } else if ([loaderType isEqualToString:@"fabric"]) {
            // For Fabric, we no longer present the FabricInstallViewController UI.
            // Instead, we automatically fetch the appropriate loader version.
            // Determine if a beta loader is desired based on the version string.
            NSString *versionStr = installerInfo[@"versionString"]; // e.g. "1.20.1" or "1.20.1-beta"
            BOOL useBetaLoader = NO;
            NSString *gameVersion = versionStr;
            NSRange betaRange = [versionStr rangeOfString:@"beta" options:NSCaseInsensitiveSearch];
            if (betaRange.location != NSNotFound) {
                useBetaLoader = YES;
                NSMutableString *cleanVersion = [versionStr mutableCopy];
                [cleanVersion replaceCharactersInRange:betaRange withString:@""];
                gameVersion = [cleanVersion stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"- "]];
            }
            NSLog(@"[ModloaderInstaller] Installing Fabric for Minecraft %@ (Loader: %@)", gameVersion, useBetaLoader ? @"Latest Beta" : @"Latest Release");
            // Fetch Fabric loader versions for the given game version
            NSString *loaderMetaURL = [NSString stringWithFormat:@"https://meta.fabricmc.net/v2/versions/loader/%@", gameVersion];
            AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
            [manager GET:loaderMetaURL parameters:nil headers:nil progress:nil
                 success:^(NSURLSessionTask *task, NSArray *responseObject) {
                     NSString *selectedLoaderVersion = nil;
                     for (NSDictionary *entry in responseObject) {
                         NSDictionary *loaderInfo = entry[@"loader"];
                         BOOL isStable = [loaderInfo[@"stable"] boolValue];
                         if (useBetaLoader) {
                             if (!isStable) {
                                 selectedLoaderVersion = loaderInfo[@"version"];
                                 break;
                             }
                         } else {
                             if (isStable) {
                                 selectedLoaderVersion = loaderInfo[@"version"];
                                 break;
                             }
                         }
                     }
                     if (!selectedLoaderVersion && responseObject.count > 0) {
                         selectedLoaderVersion = [responseObject[0][@"loader"][@"version"] copy];
                         NSLog(@"[ModloaderInstaller] No %@ loader found; using %@ as fallback.",
                               useBetaLoader ? @"unstable" : @"stable", selectedLoaderVersion);
                     }
                     if (!selectedLoaderVersion) {
                         NSLog(@"[ModloaderInstaller] Fabric loader metadata not found for game version %@", gameVersion);
                         return;
                     }
                     // Download the Fabric profile JSON for the selected loader and game version
                     NSString *profileURL = [NSString stringWithFormat:@"https://meta.fabricmc.net/v2/versions/loader/%@/%@/profile/json", gameVersion, selectedLoaderVersion];
                     [manager GET:profileURL parameters:nil headers:nil progress:nil
                          success:^(NSURLSessionTask *task, id profileResponse) {
                              if (![profileResponse isKindOfClass:[NSDictionary class]]) {
                                  NSLog(@"[ModloaderInstaller] Unexpected response for Fabric profile JSON.");
                                  return;
                              }
                              NSDictionary *profileJson = (NSDictionary *)profileResponse;
                              NSString *versionId = profileJson[@"id"];
                              const char *gameDirC = getenv("POJAV_GAME_DIR");
                              if (!gameDirC) {
                                  NSLog(@"[ModloaderInstaller] POJAV_GAME_DIR not set; cannot save Fabric profile.");
                                  return;
                              }
                              NSString *gameDir = [NSString stringWithUTF8String:gameDirC];
                              NSString *versionDir = [gameDir stringByAppendingPathComponent:[NSString stringWithFormat:@"versions/%@", versionId]];
                              if (![[NSFileManager defaultManager] createDirectoryAtPath:versionDir withIntermediateDirectories:YES attributes:nil error:nil]) {
                                  NSLog(@"[ModloaderInstaller] Failed to create directory for version %@", versionId);
                                  return;
                              }
                              NSString *jsonPath = [versionDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", versionId]];
                              NSError *writeError = nil;
                              NSData *jsonData = [NSJSONSerialization dataWithJSONObject:profileJson options:0 error:&writeError];
                              if (writeError) {
                                  NSLog(@"[ModloaderInstaller] Error serializing Fabric JSON: %@", writeError.localizedDescription);
                                  return;
                              }
                              if (![jsonData writeToFile:jsonPath options:NSDataWritingAtomic error:&writeError]) {
                                  NSLog(@"[ModloaderInstaller] Error writing Fabric JSON to file: %@", writeError.localizedDescription);
                                  return;
                              }
                              NSLog(@"[ModloaderInstaller] Successfully installed Fabric loader %@ for Minecraft %@.", selectedLoaderVersion, gameVersion);
                          } failure:^(NSURLSessionTask *task, NSError *error) {
                              NSLog(@"[ModloaderInstaller] Failed to download Fabric profile JSON: %@", error.localizedDescription);
                          }];
                 } failure:^(NSURLSessionTask *task, NSError *error) {
                     NSLog(@"[ModloaderInstaller] Failed to fetch Fabric loader versions: %@", error.localizedDescription);
                 }];
        }
        // Remove installer file after processing
        NSString *installerPath = [modpackDirectory stringByAppendingPathComponent:@"modloader_installer.json"];
        NSError *removeError = nil;
        if (![[NSFileManager defaultManager] removeItemAtPath:installerPath error:&removeError]) {
            NSLog(@"[ModloaderInstaller] Failed to remove installer file: %@", removeError.localizedDescription);
        }
    }
}

@end
