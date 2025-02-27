#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ModloaderInstaller : NSObject

/**
 Creates an installer file (modloader_installer.json) in the given modpack directory.
 This file contains the loader type (e.g. "forge" or "fabric") and the version string
 that should be installed.
 
 @param modpackDir The directory of the modpack.
 @param versionString The version string for the modloader.
 @param loaderType The type of modloader ("forge" or "fabric").
 @param error On input, a pointer to an NSError object that, if an error occurs, will be set to an error object.
 @return YES if the file was created successfully; NO otherwise.
 */
+ (BOOL)createInstallerFileInModpackDirectory:(NSString *)modpackDir
                             withVersionString:(NSString *)versionString
                                     loaderType:(NSString *)loaderType
                                          error:(NSError **)error;

/**
 Reads the installer info from the modpack directory.
 
 @param modpackDir The modpack directory.
 @param error If an error occurs, upon return contains an NSError object describing the error.
 @return A dictionary with keys "loaderType" and "versionString", or nil if reading fails.
 */
+ (nullable NSDictionary *)readInstallerInfoFromModpackDirectory:(NSString *)modpackDir
                                                          error:(NSError **)error;

/**
 Removes the installer file from the modpack directory.
 
 @param modpackDir The modpack directory.
 */
+ (void)removeInstallerFileFromModpackDirectory:(NSString *)modpackDir;

/**
 Performs the modloader installation for the modpack directory. This method will
 automatically install the modloader (Forge or Fabric) as a separate profile.
 
 @param modpackDir The modpack directory.
 @param vc The view controller from which to present any required UI.
 @param completion A block that is called when installation is finished, with a BOOL success flag.
 */
+ (void)performModloaderInstallationForModpackDirectory:(NSString *)modpackDir
                                     fromViewController:(UIViewController *)vc
                                             completion:(void (^)(BOOL success))completion;

@end

NS_ASSUME_NONNULL_END
