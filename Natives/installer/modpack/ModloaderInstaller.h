#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ModloaderInstaller : NSObject

+ (BOOL)createInstallerFileInModpackDirectory:(NSString *)modpackDir
                             withVersionString:(NSString *)versionString
                                     loaderType:(NSString *)loaderType
                                          error:(NSError **)error;

+ (nullable NSDictionary *)readInstallerInfoFromModpackDirectory:(NSString *)modpackDir
                                                          error:(NSError **)error;

+ (void)removeInstallerFileFromModpackDirectory:(NSString *)modpackDir;

+ (void)performModloaderInstallationForModpackDirectory:(NSString *)modpackDir
                                     fromViewController:(UIViewController *)vc
                                             completion:(void (^)(BOOL success))completion;

@end

NS_ASSUME_NONNULL_END
