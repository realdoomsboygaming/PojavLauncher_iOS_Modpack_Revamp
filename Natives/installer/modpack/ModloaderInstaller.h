#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ModloaderInstaller : NSObject

/**
 Creates an installer file in the given modpack directory.

 @param modpackDirectory The path to the modpack directory.
 @param versionString The parsed version string (e.g. "1.20.1-forge-43.1.0").
 @param loaderType A string indicating the mod loader type (e.g. @"forge", @"fabric").
 @param error An optional error pointer.
 @return YES if the file was successfully created; otherwise NO.
 */
+ (BOOL)createInstallerFileInModpackDirectory:(NSString *)modpackDirectory
                             withVersionString:(NSString *)versionString
                                   loaderType:(NSString *)loaderType
                                        error:(NSError **)error;

/**
 Reads the installer file from the given modpack directory.

 @param modpackDirectory The path to the modpack directory.
 @param error An optional error pointer.
 @return A dictionary with installer info if the file exists and is valid; otherwise nil.
 */
+ (nullable NSDictionary *)readInstallerInfoFromModpackDirectory:(NSString *)modpackDirectory
                                                          error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
