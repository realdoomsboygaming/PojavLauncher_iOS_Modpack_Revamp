#import "AFNetworking.h"
#import "FabricInstallViewController.h"
#import "FabricUtils.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "LauncherProfileEditorViewController.h"
#import "PickTextField.h"
#import "PLProfiles.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import "ModloaderInstaller.h"  // For modloader installer file parsing
#import <objc/runtime.h>  // :contentReference[oaicite:3]{index=3}

@interface FabricInstallViewController ()
@property (nonatomic, strong) NSDictionary *endpoints;
@property (nonatomic, strong) NSMutableDictionary *localKVO;
@property (nonatomic, strong) NSArray<NSDictionary *> *loaderMetadata;
@property (nonatomic, strong) NSMutableArray<NSString *> *loaderList;
@property (nonatomic, strong) NSArray<NSDictionary *> *versionMetadata;
@property (nonatomic, strong) NSMutableArray<NSString *> *versionList;
@end

@implementation FabricInstallViewController

- (void)viewDidLoad {
    self.title = localize(@"profile.title.install_fabric_quilt", nil);
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(actionDone:)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(actionClose)];
    
    self.prefSectionsVisible = YES;
    __weak __typeof(self) weakSelf = self;
    self.localKVO = [@{
        @"gameVersion": @"1.20.1",
        @"loaderVendor": @"Fabric",
        @"loaderVersion": @"0.14.22"
    } mutableCopy];
    self.getPreference = ^id(NSString *section, NSString *key) {
        return weakSelf.localKVO[key];
    };
    self.setPreference = ^(NSString *section, NSString *key, NSString *value) {
        weakSelf.localKVO[key] = value;
    };
    
    id typePickSegment = ^(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item) {
        UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:item[@"pickList"]];
        [seg addTarget:weakSelf action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
        if (seg.selectedSegmentIndex == UISegmentedControlNoSegment) {
            seg.selectedSegmentIndex = 0;
        }
        cell.accessoryView = seg;
    };
    
    self.versionList = [NSMutableArray new];
    self.loaderList = [NSMutableArray new];
    self.prefContents = @[
      @[
        @{@"key": @"gameType",
          @"icon": @"ladybug",
          @"title": @"preference.profile.title.version_type",
          @"type": typePickSegment,
          @"pickList": @[localize(@"Release", nil), localize(@"Snapshot", nil)],
          @"action": ^(int type) {
              [weakSelf changeVersionTypeTo:type];
          }},
        @{@"key": @"gameVersion",
          @"icon": @"archivebox",
          @"title": @"preference.profile.title.version",
          @"type": self.typePickField,
          @"pickKeys": self.versionList,
          @"pickList": self.versionList},
        @{@"key": @"loaderVendor",
          @"icon": @"folder.badge.gearshape",
          @"title": @"preference.profile.title.loader_vendor",
          @"type": typePickSegment,
          @"pickList": @[@"Fabric", @"Quilt"],
          @"action": ^(int vendor){
              [weakSelf fetchVersionEndpoints:vendor];
          }},
        @{@"key": @"loaderType",
          @"icon": @"ladybug",
          @"title": @"preference.profile.title.loader_type",
          @"type": typePickSegment,
          @"pickList": @[localize(@"Release", nil), @"Unstable"],
          @"action": ^(int type) {
              [weakSelf changeLoaderTypeTo:type];
          }},
        @{@"key": @"loaderVersion",
          @"icon": @"doc.badge.gearshape",
          @"title": @"preference.profile.title.loader_version",
          @"type": self.typePickField,
          @"pickKeys": self.loaderList,
          @"pickList": self.loaderList}
      ]
    ];
    
    [super viewDidLoad];
    self.endpoints = FabricUtils.endpoints;
    [self fetchVersionEndpoints:0];
    
    // New functionality: if a modloader installer file exists, parse its modloader version and restrict UI accordingly.
    if (self.modpackDirectory) {
        NSError *error = nil;
        NSDictionary *installerInfo = [ModloaderInstaller readInstallerInfoFromModpackDirectory:self.modpackDirectory error:&error];
        if (installerInfo) {
            NSString *versionString = installerInfo[@"versionString"];
            [self.versionList removeAllObjects];
            [self.loaderList removeAllObjects];
            [self.versionList addObject:versionString];
            [self.loaderList addObject:installerInfo[@"loaderType"] ?: versionString];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.tableView reloadData];
            });
        }
    }
}

- (void)fetchVersionEndpoints:(int)type {
    __block BOOL errorShown = NO;
    void (^errorCallback)(NSURLSessionTask *, NSError *) = ^(NSURLSessionTask *op, NSError *error) {
        if (!errorShown) {
            errorShown = YES;
            NSLog(@"Error: %@", error);
            showDialog(localize(@"Error", nil), error.localizedDescription);
            [self actionClose];
        }
    };
    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    NSDictionary *endpoint = self.endpoints[self.localKVO[@"loaderVendor"]];
    [manager GET:endpoint[@"game"] parameters:nil headers:nil progress:nil success:^(NSURLSessionTask *task, NSArray *response) {
        NSLog(@"[%@ Installer] Got %lu game versions", self.localKVO[@"loaderVendor"], (unsigned long)response.count);
        self.versionMetadata = response;
        [self changeVersionTypeTo:[self.localKVO[@"gameType_index"] intValue]];
    } failure:errorCallback];
    [manager GET:endpoint[@"loader"] parameters:nil headers:nil progress:nil success:^(NSURLSessionTask *task, NSArray *response) {
        NSLog(@"[%@ Installer] Got %lu loader versions", self.localKVO[@"loaderVendor"], (unsigned long)response.count);
        self.loaderMetadata = response;
        [self changeLoaderTypeTo:[self.localKVO[@"loaderType_index"] intValue]];
    } failure:errorCallback];
}

- (void)actionClose {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (void)actionDone:(UIBarButtonItem *)sender {
    sender.enabled = NO;
    NSDictionary *endpoint = self.endpoints[self.localKVO[@"loaderVendor"]];
    NSString *path = [NSString stringWithFormat:endpoint[@"json"], self.localKVO[@"gameVersion"], self.localKVO[@"loaderVersion"]];
    NSLog(@"[%@ Installer] Downloading %@", self.localKVO[@"loaderVendor"], path);
    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    [manager GET:path parameters:nil headers:nil progress:nil success:^(NSURLSessionTask *task, NSDictionary *response) {
        sender.enabled = YES;
        NSString *jsonPath = [NSString stringWithFormat:@"%s/versions/%@/%@.json", getenv("POJAV_GAME_DIR"), response[@"id"], response[@"id"]];
        [[NSFileManager defaultManager] createDirectoryAtPath:[jsonPath stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
        NSError *error = saveJSONToFile(response, jsonPath);
        if (error) {
            showDialog(localize(@"Error", nil), error.localizedDescription);
        } else {
            [localVersionList addObject:@{@"id": response[@"id"], @"type": @"custom"}];
            LauncherProfileEditorViewController *vc = [LauncherProfileEditorViewController new];
            vc.profile = [@{@"icon": endpoint[@"icon"], @"name": response[@"id"], @"lastVersionId": response[@"id"]} mutableCopy];
            [self.navigationController pushViewController:vc animated:YES];
        }
    } failure:^(NSURLSessionTask *operation, NSError *error) {
        sender.enabled = YES;
        NSLog(@"Error: %@", error);
        showDialog(localize(@"Error", nil), error.localizedDescription);
    }];
}

- (void)changeVersionTypeTo:(int)type {
    [self.versionList removeAllObjects];
    for (NSDictionary *version in self.versionMetadata) {
        BOOL isStable = [version[@"stable"] boolValue];
        if ((type == 0 && isStable) || (type != 0 && !isStable)) {
            [self.versionList addObject:version[@"version"]];
        }
    }
    self.localKVO[@"gameVersion"] = self.versionList.firstObject ?: @"";
    [self.tableView reloadData];
}

- (void)changeLoaderTypeTo:(int)type {
    [self.loaderList removeAllObjects];
    for (NSDictionary *version in self.loaderMetadata) {
        BOOL isStable = [version[@"stable"] boolValue];
        if ((type == 0 && isStable) || (type != 0 && !isStable)) {
            [self.loaderList addObject:version[@"version"]];
        }
    }
    self.localKVO[@"loaderVersion"] = self.loaderList.firstObject ?: @"";
    [self.tableView reloadData];
}

- (void)segmentChanged:(UISegmentedControl *)segment {
    // Additional handling if needed
}

@end
