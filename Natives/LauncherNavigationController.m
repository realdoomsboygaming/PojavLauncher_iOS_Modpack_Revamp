#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "authenticator/BaseAuthenticator.h"
#import "AFNetworking.h"
#import "ALTServerConnection.h"
#import "CustomControlsViewController.h"
#import "DownloadProgressViewController.h"
#import "JavaGUIViewController.h"
#import "LauncherMenuViewController.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "MinecraftResourceDownloadTask.h"
#import "MinecraftResourceUtils.h"
#import "PickTextField.h"
#import "PLPickerView.h"
#import "PLProfiles.h"
#import "UIKit+AFNetworking.h"
#import "UIKit+hook.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import "installer/modpack/ModloaderInstaller.h"
#import "installer/modpack/CurseForgeAPI.h"
#import "installer/ForgeInstallViewController.h"
#import "installer/FabricInstallViewController.h"

#include <sys/time.h>

#define AUTORESIZE_MASKS UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin

static void *ProgressObserverContext = &ProgressObserverContext;

@interface LauncherNavigationController () <UIDocumentPickerDelegate, UIPickerViewDataSource, PLPickerViewDelegate, UIPopoverPresentationControllerDelegate>

@property(nonatomic) MinecraftResourceDownloadTask *task;
@property(nonatomic) DownloadProgressViewController *progressVC;
@property(nonatomic) PLPickerView *versionPickerView;
@property(nonatomic) UITextField *versionTextField;
@property(nonatomic) int profileSelectedAt;

// Added for modloader installation handling:
@property(nonatomic, assign) BOOL modloaderInstallPending;

@end

@implementation LauncherNavigationController

#pragma mark - View Lifecycle

- (void)viewDidLoad
{
    [super viewDidLoad];

    if ([self respondsToSelector:@selector(setNeedsUpdateOfScreenEdgesDeferringSystemGestures)]) {
        [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
    }

    self.versionTextField = [[PickTextField alloc] initWithFrame:CGRectMake(4, 4, self.toolbar.frame.size.width * 0.8 - 8, self.toolbar.frame.size.height - 8)];
    [self.versionTextField addTarget:self.versionTextField action:@selector(resignFirstResponder) forControlEvents:UIControlEventEditingDidEndOnExit];
    self.versionTextField.autoresizingMask = AUTORESIZE_MASKS;
    self.versionTextField.placeholder = @"Specify version...";
    self.versionTextField.leftView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 40, 40)];
    self.versionTextField.rightView = [[UIImageView alloc] initWithImage:[[UIImage imageNamed:@"SpinnerArrow"] _imageWithSize:CGSizeMake(30, 30)]];
    self.versionTextField.rightView.frame = CGRectMake(0, 0, self.versionTextField.frame.size.height * 0.9, self.versionTextField.frame.size.height * 0.9);
    self.versionTextField.leftViewMode = UITextFieldViewModeAlways;
    self.versionTextField.rightViewMode = UITextFieldViewModeAlways;
    self.versionTextField.textAlignment = NSTextAlignmentCenter;

    self.versionPickerView = [[PLPickerView alloc] init];
    self.versionPickerView.delegate = self;
    self.versionPickerView.dataSource = self;
    UIToolbar *versionPickToolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0.0, 0.0, self.view.frame.size.width, 44.0)];

    [self reloadProfileList];

    UIBarButtonItem *versionFlexibleSpace = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:self action:nil];
    UIBarButtonItem *versionDoneButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(versionClosePicker)];
    versionPickToolbar.items = @[versionFlexibleSpace, versionDoneButton];
    self.versionTextField.inputAccessoryView = versionPickToolbar;
    self.versionTextField.inputView = self.versionPickerView;

    UIView *targetToolbar = self.toolbar;
    [targetToolbar addSubview:self.versionTextField];

    self.progressViewMain = [[UIProgressView alloc] initWithFrame:CGRectMake(0, 0, self.toolbar.frame.size.width, 4)];
    self.progressViewMain.autoresizingMask = AUTORESIZE_MASKS;
    self.progressViewMain.hidden = YES;
    [targetToolbar addSubview:self.progressViewMain];

    self.buttonInstall = [UIButton buttonWithType:UIButtonTypeSystem];
    setButtonPointerInteraction(self.buttonInstall);
    [self.buttonInstall setTitle:localize(@"Play", nil) forState:UIControlStateNormal];
    self.buttonInstall.autoresizingMask = AUTORESIZE_MASKS;
    self.buttonInstall.backgroundColor = [UIColor colorWithRed:54/255.0 green:176/255.0 blue:48/255.0 alpha:1.0];
    self.buttonInstall.layer.cornerRadius = 5;
    self.buttonInstall.frame = CGRectMake(self.toolbar.frame.size.width * 0.8, 4, self.toolbar.frame.size.width * 0.2, self.toolbar.frame.size.height - 8);
    self.buttonInstall.tintColor = UIColor.whiteColor;
    self.buttonInstall.enabled = NO;
    [self.buttonInstall addTarget:self action:@selector(performInstallOrShowDetails:) forControlEvents:UIControlEventPrimaryActionTriggered];
    [targetToolbar addSubview:self.buttonInstall];

    self.progressText = [[UILabel alloc] initWithFrame:self.versionTextField.frame];
    self.progressText.adjustsFontSizeToFitWidth = YES;
    self.progressText.autoresizingMask = AUTORESIZE_MASKS;
    self.progressText.font = [self.progressText.font fontWithSize:16];
    self.progressText.textAlignment = NSTextAlignmentCenter;
    self.progressText.userInteractionEnabled = NO;
    [targetToolbar addSubview:self.progressText];

    [self fetchRemoteVersionList];
    [NSNotificationCenter.defaultCenter addObserver:self
                                             selector:@selector(receiveNotification:)
                                                 name:@"InstallModpack"
                                               object:nil];

    if ([BaseAuthenticator.current isKindOfClass:MicrosoftAuthenticator.class]) {
        [self setInteractionEnabled:NO forDownloading:NO];
        id callback = ^(NSString *status, BOOL success) {
            self.progressText.text = status;
            if (status == nil) {
                [self setInteractionEnabled:YES forDownloading:NO];
            } else if (!success) {
                showDialog(localize(@"Error", nil), status);
            }
        };
        [BaseAuthenticator.current refreshTokenWithCallback:callback];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self reloadProfileList];
    [self updateModloaderInstallStatus];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [sidebarViewController updateAccountInfo];
}

#pragma mark - Local & Remote Version List

- (BOOL)isVersionInstalled:(NSString *)versionId {
    NSString *localPath = [NSString stringWithFormat:@"%s/versions/%@", getenv("POJAV_GAME_DIR"), versionId];
    BOOL isDirectory;
    [NSFileManager.defaultManager fileExistsAtPath:localPath isDirectory:&isDirectory];
    return isDirectory;
}

- (void)fetchLocalVersionList {
    if (!localVersionList) {
        localVersionList = [NSMutableArray new];
    }
    [localVersionList removeAllObjects];

    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *versionPath = [NSString stringWithFormat:@"%s/versions/", getenv("POJAV_GAME_DIR")];
    NSArray *list = [fileManager contentsOfDirectoryAtPath:versionPath error:nil];
    for (NSString *versionId in list) {
        if (![self isVersionInstalled:versionId]) continue;
        [localVersionList addObject:@{@"id": versionId, @"type": @"custom"}];
    }
}

- (void)fetchRemoteVersionList {
    self.buttonInstall.enabled = NO;
    remoteVersionList = [@[
        @{@"id": @"latest-release", @"type": @"release"},
        @{@"id": @"latest-snapshot", @"type": @"snapshot"}
    ] mutableCopy];

    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    [manager GET:@"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json" parameters:nil headers:nil progress:^(NSProgress * _Nonnull progress) {
        self.progressViewMain.progress = progress.fractionCompleted;
    } success:^(NSURLSessionTask *task, NSDictionary *responseObject) {
        [remoteVersionList addObjectsFromArray:responseObject[@"versions"]];
        NSDebugLog(@"[VersionList] Got %d versions", remoteVersionList.count);
        setPrefObject(@"internal.latest_version", responseObject[@"latest"]);
        self.buttonInstall.enabled = YES;
    } failure:^(NSURLSessionTask *operation, NSError *error) {
        NSDebugLog(@"[VersionList] Warning: Unable to fetch version list: %@", error.localizedDescription);
        self.buttonInstall.enabled = YES;
    }];
}

- (void)reloadProfileList {
    [self fetchLocalVersionList];
    [PLProfiles updateCurrent];
    [self.versionPickerView reloadAllComponents];
    self.profileSelectedAt = [PLProfiles.current.profiles.allKeys indexOfObject:PLProfiles.current.selectedProfileName];
    if (self.profileSelectedAt == -1) return;
    [self.versionPickerView selectRow:self.profileSelectedAt inComponent:0 animated:NO];
    [self pickerView:self.versionPickerView didSelectRow:self.profileSelectedAt inComponent:0];
}

#pragma mark - Modloader Installation

- (void)updateModloaderInstallStatus {
    NSDictionary *profile = PLProfiles.current.profiles[PLProfiles.current.selectedProfileName];
    if (!profile) {
        self.modloaderInstallPending = NO;
        [self.buttonInstall setTitle:localize(@"Play", nil) forState:UIControlStateNormal];
        return;
    }
    NSString *gameDir = profile[@"gameDir"];
    if (!gameDir.length) {
        self.modloaderInstallPending = NO;
        [self.buttonInstall setTitle:localize(@"Play", nil) forState:UIControlStateNormal];
        return;
    }
    // Construct full modpack path using current directory and gameDir.
    NSString *modpackPath = [[NSFileManager defaultManager] currentDirectoryPath];
    if ([gameDir hasPrefix:@"./"]) {
        gameDir = [gameDir substringFromIndex:2];
    }
    NSString *fullPath = [modpackPath stringByAppendingPathComponent:gameDir];
    NSError *error = nil;
    NSDictionary *installerInfo = [ModloaderInstaller readInstallerInfoFromModpackDirectory:fullPath error:&error];
    if (installerInfo && [installerInfo[@"installOnFirstLaunch"] boolValue]) {
         self.modloaderInstallPending = YES;
         [self.buttonInstall setTitle:localize(@"Install", nil) forState:UIControlStateNormal];
    } else {
         self.modloaderInstallPending = NO;
         [self.buttonInstall setTitle:localize(@"Play", nil) forState:UIControlStateNormal];
    }
}

- (void)checkAndInstallModloaderIfNeeded {
    NSDictionary *profile = PLProfiles.current.profiles[PLProfiles.current.selectedProfileName];
    if (!profile) return;
    NSString *gameDir = profile[@"gameDir"];
    if (!gameDir.length) return;
    NSString *modpackPath = [[NSFileManager defaultManager] currentDirectoryPath];
    if ([gameDir hasPrefix:@"./"]) {
        gameDir = [gameDir substringFromIndex:2];
    }
    NSString *fullPath = [modpackPath stringByAppendingPathComponent:gameDir];
    [ModloaderInstaller performModloaderInstallationForModpackDirectory:fullPath fromViewController:self];
}

#pragma mark - Options

- (void)enterCustomControls {
    CustomControlsViewController *vc = [[CustomControlsViewController alloc] init];
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    vc.setDefaultCtrl = ^(NSString *name){
        setPrefObject(@"control.default_ctrl", name);
    };
    vc.getDefaultCtrl = ^{
        return getPrefObject(@"control.default_ctrl");
    };
    [self presentViewController:vc animated:YES completion:nil];
}

- (void)enterModInstaller {
    UIDocumentPickerViewController *documentPicker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[[UTType typeWithMIMEType:@"application/java-archive"]]
        asCopy:YES];
    documentPicker.delegate = self;
    documentPicker.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:documentPicker animated:YES completion:nil];
}

- (void)enterModInstallerWithPath:(NSString *)path hitEnterAfterWindowShown:(BOOL)hitEnter {
    JavaGUIViewController *vc = [[JavaGUIViewController alloc] init];
    vc.filepath = path;
    vc.hitEnterAfterWindowShown = hitEnter;
    if (!vc.requiredJavaVersion) return;
    [self invokeAfterJITEnabled:^{
        vc.modalPresentationStyle = UIModalPresentationFullScreen;
        NSLog(@"[ModInstaller] launching %@", vc.filepath);
        [self presentViewController:vc animated:YES completion:nil];
    }];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentAtURL:(NSURL *)url {
    [self enterModInstallerWithPath:url.path hitEnterAfterWindowShown:NO];
}

#pragma mark - Interaction & Launch

- (void)setInteractionEnabled:(BOOL)enabled forDownloading:(BOOL)downloading {
    for (UIControl *view in self.toolbar.subviews) {
        if ([view isKindOfClass:UIControl.class]) {
            view.alpha = enabled ? 1 : 0.2;
            view.enabled = enabled;
        }
    }
    self.progressViewMain.hidden = enabled;
    self.progressText.text = nil;
    if (downloading) {
        [self.buttonInstall setTitle:localize(enabled ? @"Play" : @"Details", nil) forState:UIControlStateNormal];
        self.buttonInstall.alpha = 1;
        self.buttonInstall.enabled = YES;
    }
    UIApplication.sharedApplication.idleTimerDisabled = !enabled;
}

- (void)launchMinecraft:(UIButton *)sender {
    if (!self.versionTextField.hasText) {
        [self.versionTextField becomeFirstResponder];
        return;
    }
    
    // Check if a modpack installer file exists that indicates modloader installation is needed.
    NSDictionary *profile = PLProfiles.current.profiles[PLProfiles.current.selectedProfileName];
    NSString *gameDir = profile[@"gameDir"];
    if (gameDir.length) {
        NSString *modpackPath = [[NSFileManager defaultManager] currentDirectoryPath];
        if ([gameDir hasPrefix:@"./"]) {
            gameDir = [gameDir substringFromIndex:2];
        }
        NSString *fullPath = [modpackPath stringByAppendingPathComponent:gameDir];
        NSError *readError = nil;
        NSDictionary *installerInfo = [ModloaderInstaller readInstallerInfoFromModpackDirectory:fullPath error:&readError];
        if (installerInfo && [installerInfo[@"installOnFirstLaunch"] boolValue]) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"Modloader Installation", nil)
                                                                           message:localize(@"In order to play, the modloader needs to be installed.", nil)
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            UIAlertAction *understandAction = [UIAlertAction actionWithTitle:localize(@"I understand", nil)
                                                                       style:UIAlertActionStyleDefault
                                                                     handler:^(UIAlertAction * _Nonnull action) {
                [ModloaderInstaller performModloaderInstallationForModpackDirectory:fullPath fromViewController:self];
            }];
            [alert addAction:understandAction];
            [self presentViewController:alert animated:YES completion:nil];
            return;
        }
    }
    
    if (BaseAuthenticator.current == nil) {
        UIViewController *view = [(UINavigationController *)self.splitViewController.viewControllers[0] viewControllers][0];
        [view performSelector:@selector(selectAccount:) withObject:sender];
        return;
    }
    
    [self setInteractionEnabled:NO forDownloading:YES];
    
    NSString *versionId = PLProfiles.current.profiles[self.versionTextField.text][@"lastVersionId"];
    NSDictionary *object = [[remoteVersionList filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"(id == %@)", versionId]] firstObject];
    if (!object) {
        object = @{@"id": versionId, @"type": @"custom"};
    }
    
    self.task = [MinecraftResourceDownloadTask new];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __weak LauncherNavigationController *weakSelf = self;
        self.task.handleError = ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf setInteractionEnabled:YES forDownloading:YES];
                weakSelf.task = nil;
                weakSelf.progressVC = nil;
            });
        };
        [self.task downloadVersion:object];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.progressViewMain.observedProgress = self.task.progress;
            [self.task.progress addObserver:self
                                  forKeyPath:@"fractionCompleted"
                                     options:NSKeyValueObservingOptionInitial
                                     context:ProgressObserverContext];
        });
    });
}

- (void)performInstallOrShowDetails:(UIButton *)sender {
    if (self.modloaderInstallPending) {
        [self checkAndInstallModloaderIfNeeded];
        self.modloaderInstallPending = NO;
        [self.buttonInstall setTitle:localize(@"Play", nil) forState:UIControlStateNormal];
        return;
    }
    
    if (self.task) {
        if (!self.progressVC) {
            self.progressVC = [[DownloadProgressViewController alloc] initWithTask:self.task];
        }
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:self.progressVC];
        nav.modalPresentationStyle = UIModalPresentationPopover;
        nav.popoverPresentationController.sourceView = sender;
        [self presentViewController:nav animated:YES completion:nil];
    } else {
        [self launchMinecraft:sender];
    }
}

#pragma mark - KVO

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != ProgressObserverContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    
    static CGFloat lastMsTime;
    static NSUInteger lastSecTime, lastCompletedUnitCount;
    NSProgress *progress = self.task.textProgress;
    struct timeval tv;
    gettimeofday(&tv, NULL);
    NSInteger completedUnitCount = self.task.progress.totalUnitCount * self.task.progress.fractionCompleted;
    progress.completedUnitCount = completedUnitCount;
    if (lastSecTime < tv.tv_sec) {
        CGFloat currentTime = tv.tv_sec + tv.tv_usec / 1000000.0;
        NSInteger throughput = (completedUnitCount - lastCompletedUnitCount) / (currentTime - lastMsTime);
        progress.throughput = @(throughput);
        progress.estimatedTimeRemaining = @((progress.totalUnitCount - completedUnitCount) / throughput);
        lastCompletedUnitCount = completedUnitCount;
        lastSecTime = tv.tv_sec;
        lastMsTime = currentTime;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        self.progressText.text = progress.localizedAdditionalDescription;
        
        if (!progress.finished) return;
        [self.progressVC dismissViewControllerAnimated:NO completion:nil];
        
        self.progressViewMain.observedProgress = nil;
        if (self.task.metadata) {
            [self invokeAfterJITEnabled:^{
                UIKit_launchMinecraftSurfaceVC(self.view.window, self.task.metadata);
            }];
        } else {
            self.task = nil;
            [self setInteractionEnabled:YES forDownloading:YES];
            [self reloadProfileList];
        }
    });
}

#pragma mark - Notifications

- (void)receiveNotification:(NSNotification *)notification {
    if (![notification.name isEqualToString:@"InstallModpack"]) {
        return;
    }
    [self setInteractionEnabled:NO forDownloading:YES];
    self.task = [MinecraftResourceDownloadTask new];
    NSDictionary *userInfo = notification.userInfo;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __weak LauncherNavigationController *weakSelf = self;
        self.task.handleError = ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf setInteractionEnabled:YES forDownloading:YES];
                weakSelf.task = nil;
                weakSelf.progressVC = nil;
            });
        };
        [self.task downloadModpackFromAPI:notification.object detail:userInfo[@"detail"] atIndex:[userInfo[@"index"] unsignedLongValue]];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.progressViewMain.observedProgress = self.task.progress;
            [self.task.progress addObserver:self
                                  forKeyPath:@"fractionCompleted"
                                     options:NSKeyValueObservingOptionInitial
                                     context:ProgressObserverContext];
        });
    });
}

#pragma mark - JIT Handling

- (void)invokeAfterJITEnabled:(void(^)(void))handler {
    localVersionList = remoteVersionList = nil;
    BOOL hasTrollStoreJIT = getEntitlementValue(@"com.apple.private.local.sandboxed-jit");

    if (isJITEnabled(false)) {
        [ALTServerManager.sharedManager stopDiscovering];
        handler();
        return;
    } else if (hasTrollStoreJIT) {
        NSURL *jitURL = [NSURL URLWithString:[NSString stringWithFormat:@"apple-magnifier://enable-jit?bundle-id=%@", NSBundle.mainBundle.bundleIdentifier]];
        [UIApplication.sharedApplication openURL:jitURL options:@{} completionHandler:nil];
    } else if (getPrefBool(@"debug.debug_skip_wait_jit")) {
        NSLog(@"Debug option skipped waiting for JIT. Java might not work.");
        handler();
        return;
    }

    self.progressText.text = localize(@"launcher.wait_jit.title", nil);

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"launcher.wait_jit.title", nil)
                                                                   message:hasTrollStoreJIT ? localize(@"launcher.wait_jit_trollstore.message", nil) : localize(@"launcher.wait_jit.message", nil)
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:alert animated:YES completion:nil];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        while (!isJITEnabled(false)) {
            usleep(1000 * 200);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [alert dismissViewControllerAnimated:YES completion:handler];
        });
    });
}

#pragma mark - UIPopoverPresentationControllerDelegate

- (UIModalPresentationStyle)adaptivePresentationStyleForPresentationController:(UIPresentationController *)controller traitCollection:(UITraitCollection *)traitCollection {
    return UIModalPresentationNone;
}

#pragma mark - UIPickerView Methods

- (void)pickerView:(PLPickerView *)pickerView didSelectRow:(NSInteger)row inComponent:(NSInteger)component {
    self.profileSelectedAt = row;
    ((UIImageView *)self.versionTextField.leftView).image = [pickerView imageAtRow:row column:component];
    self.versionTextField.text = [self pickerView:pickerView titleForRow:row forComponent:component];
    PLProfiles.current.selectedProfileName = self.versionTextField.text;
}

- (NSInteger)numberOfComponentsInPickerView:(UIPickerView *)pickerView {
    return 1;
}

- (NSInteger)pickerView:(UIPickerView *)pickerView numberOfRowsInComponent:(NSInteger)component {
    return PLProfiles.current.profiles.count;
}

- (NSString *)pickerView:(UIPickerView *)pickerView titleForRow:(NSInteger)row forComponent:(NSInteger)component {
    return PLProfiles.current.profiles.allValues[row][@"name"];
}

- (void)pickerView:(PLPickerView *)pickerView enumerateImageView:(UIImageView *)imageView forRow:(NSInteger)row forComponent:(NSInteger)component {
    UIImage *fallbackImage = [[UIImage imageNamed:@"DefaultProfile"] _imageWithSize:CGSizeMake(40, 40)];
    NSString *urlString = PLProfiles.current.profiles.allValues[row][@"icon"];
    [imageView setImageWithURL:[NSURL URLWithString:urlString] placeholderImage:fallbackImage];
}

- (void)versionClosePicker {
    [self.versionTextField endEditing:YES];
    [self pickerView:self.versionPickerView didSelectRow:[self.versionPickerView selectedRowInComponent:0] inComponent:0];
}

#pragma mark - View Controller UI Mode

- (BOOL)prefersHomeIndicatorAutoHidden {
    return YES;
}

@end
