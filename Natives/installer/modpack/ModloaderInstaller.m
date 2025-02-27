#import "ModloaderInstaller.h"
#import "AFNetworking.h"
#import "PLProfiles.h"

@implementation ModloaderInstaller

+ (NSString *)installerFilePathForModpackDirectory:(NSString *)modpackDir {
    return [modpackDir stringByAppendingPathComponent:@"modloader_installer.json"];
}

+ (BOOL)createInstallerFileInModpackDirectory:(NSString *)modpackDir 
                             withVersionString:(NSString *)versionString 
                                     loaderType:(NSString *)loaderType 
                                          error:(NSError **)error 
{
    NSDictionary *installerInfo = @{
        @"loaderType": loaderType,
        @"versionString": versionString
    };
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:installerInfo options:0 error:error];
    if (!jsonData) {
        return NO;
    }
    NSString *filePath = [self installerFilePathForModpackDirectory:modpackDir];
    return [jsonData writeToFile:filePath options:NSDataWritingAtomic error:error];
}

+ (NSDictionary *)readInstallerInfoFromModpackDirectory:(NSString *)modpackDir error:(NSError **)error {
    NSString *filePath = [self installerFilePathForModpackDirectory:modpackDir];
    NSData *data = [NSData dataWithContentsOfFile:filePath options:0 error:error];
    if (!data) {
        return nil;
    }
    NSDictionary *installerInfo = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    return installerInfo;
}

+ (void)removeInstallerFileFromModpackDirectory:(NSString *)modpackDir {
    NSString *filePath = [self installerFilePathForModpackDirectory:modpackDir];
    [[NSFileManager defaultManager] removeItemAtPath:filePath error:nil];
}

+ (void)performModloaderInstallationForModpackDirectory:(NSString *)modpackDir 
                                     fromViewController:(UIViewController *)vc 
                                             completion:(void (^)(BOOL success))completion 
{
    NSError *readError = nil;
    NSDictionary *installerInfo = [self readInstallerInfoFromModpackDirectory:modpackDir error:&readError];
    if (!installerInfo) {
        NSLog(@"[ModloaderInstaller] No installer info found: %@", readError.localizedDescription);
        if (completion) completion(NO);
        return;
    }
    
    NSString *loaderType = installerInfo[@"loaderType"];
    NSString *versionString = installerInfo[@"versionString"];
    
    NSLog(@"[ModloaderInstaller] Initiating installation for loader type: %@, version: %@", loaderType, versionString);
    
    if ([loaderType isEqualToString:@"forge"]) {
        // For Forge, simulate downloading the Forge installer and running it.
        // In production, you would download the installer jar and run it using appropriate Java integration.
        // Here we simulate a delay and then mark installation as successful.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSLog(@"[ModloaderInstaller] Forge installer simulated installation complete for version %@", versionString);
            // Remove installer file upon success.
            [self removeInstallerFileFromModpackDirectory:modpackDir];
            if (completion) completion(YES);
        });
    } else if ([loaderType isEqualToString:@"fabric"]) {
        // For Fabric, simulate automatic installation of the Fabric loader.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSLog(@"[ModloaderInstaller] Fabric loader simulated installation complete for version %@", versionString);
            [self removeInstallerFileFromModpackDirectory:modpackDir];
            if (completion) completion(YES);
        });
    } else {
        // Unsupported loader type – mark as failure.
        NSLog(@"[ModloaderInstaller] Unsupported modloader type: %@", loaderType);
        if (completion) completion(NO);
    }
}

@end
