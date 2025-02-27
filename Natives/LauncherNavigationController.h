#import <UIKit/UIKit.h>

extern NSMutableArray<NSDictionary *> *localVersionList, *remoteVersionList;

@interface LauncherNavigationController : UINavigationController
@property (nonatomic, strong) UIProgressView *progressViewMain, *progressViewSub;
@property (nonatomic, strong) UILabel *progressText;
@property (nonatomic, strong) UIButton *buttonInstall;
- (void)enterModInstallerWithPath:(NSString *)path hitEnterAfterWindowShown:(BOOL)hitEnter;
- (void)fetchLocalVersionList;
- (void)setInteractionEnabled:(BOOL)enable forDownloading:(BOOL)downloading;
@end
