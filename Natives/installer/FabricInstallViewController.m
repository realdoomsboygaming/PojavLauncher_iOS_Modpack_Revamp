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
#import <objc/runtime.h>

@interface FabricInstallViewController ()
@property(nonatomic, strong) NSDictionary *endpoints;
@property(nonatomic, strong) NSMutableDictionary *localKVO;
@property(nonatomic, strong) NSArray<NSDictionary *> *loaderMetadata;
@property(nonatomic, strong) NSMutableArray<NSString *> *loaderList;
@property(nonatomic, strong) NSArray<NSDictionary *> *versionMetadata;
@property(nonatomic, strong) NSMutableArray<NSString *> *versionList;
@end

@implementation FabricInstallViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = localize(@"profile.title.install_fabric_quilt", nil);
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(actionDone:)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(actionClose)];
    self.prefSectionsVisible = YES;
    __weak __typeof(self) weakSelf = self;
    self.localKVO = [@{@"gameVersion": @"1.20.1", @"loaderVendor": @"Fabric", @"loaderVersion": @"0.14.22"} mutableCopy];
    self.getPreference = ^id(NSString *section, NSString *key) {
        return weakSelf.localKVO[key];
    };
    self.setPreference = ^(NSString *section, NSString *key, NSString *value) {
        weakSelf.localKVO[key] = value;
    };
    id typePickSegment = ^(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item) {
        UISegmentedControl *view = [[UISegmentedControl alloc] initWithItems:item[@"pickList"]];
        [view addTarget:weakSelf action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
        if (view.selectedSegmentIndex == UISegmentedControlNoSegment) {
            view.selectedSegmentIndex = 0;
        }
        cell.accessoryView = view;
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
              }
            },
            @{@"key": @"gameVersion",
              @"icon": @"archivebox",
              @"title": @"preference.profile.title.version",
              @"type": self.typePickField,
              @"pickKeys": self.versionList,
              @"pickList": self.versionList
            },
            @{@"key": @"loaderVendor",
              @"icon": @"folder.badge.gearshape",
              @"title": @"preference.profile.title.loader_vendor",
              @"type": typePickSegment,
              @"pickList": @[@"Fabric", @"Quilt"],
              @"action": ^(int vendor){
                  [weakSelf fetchVersionEndpoints:vendor];
              }
            },
            @{@"key": @"loaderType",
              @"icon": @"ladybug",
              @"title": @"preference.profile.title.loader_type",
              @"type": typePickSegment,
              @"pickList": @[localize(@"Release", nil), @"Unstable"],
              @"action": ^(int type) {
                  [weakSelf changeLoaderTypeTo:type];
              }
            },
            @{@"key": @"loaderVersion",
              @"icon": @"doc.badge.gearshape",
              @"title": @"preference.profile.title.loader_version",
              @"type": self.typePickField,
              @"pickKeys": self.loaderList,
              @"pickList": self.loaderList
            }
        ]
    ];
    self.endpoints = [FabricUtils endpoints];
    [self fetchVersionEndpoints:0];
}

- (void)fetchVersionEndpoints:(int)type {
    __block BOOL errorShown = NO;
    id errorCallback = ^(NSURLSessionTask *operation, NSError *error) {
        if (!errorShown) {
            errorShown = YES;
            showDialog(localize(@"Error", nil), error.localizedDescription);
            [self actionClose];
        }
    };
    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    NSDictionary *endpoint = self.endpoints[self.localKVO[@"loaderVendor"]];
    [manager GET:endpoint[@"game"] parameters:nil headers:nil progress:nil success:^(NSURLSessionTask *task, NSArray *response) {
        self.versionMetadata = response;
        [self changeVersionTypeTo:[self.localKVO[@"gameType_index"] intValue]];
    } failure:errorCallback];
    [manager GET:endpoint[@"loader"] parameters:nil headers:nil progress:nil success:^(NSURLSessionTask *task, NSArray *response) {
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
    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    [manager GET:path parameters:nil headers:nil progress:nil success:^(NSURLSessionTask *task, NSDictionary *response) {
        sender.enabled = YES;
        NSString *jsonPath = [NSString stringWithFormat:@"%s/versions/%@/%@.json", getenv("POJAV_GAME_DIR"), response[@"id"], response[@"id"]];
        [[NSFileManager defaultManager] createDirectoryAtPath:jsonPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
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
        showDialog(localize(@"Error", nil), error.localizedDescription);
    }];
}

- (void)changeTypeToStable:(BOOL)stable forList:(NSMutableArray *)list fromMetadata:(NSArray *)metadata atRow:(int)row key:(NSString *)key {
    [list removeAllObjects];
    for (NSDictionary *version in metadata) {
        if (version[@"stable"]) {
            if ([version[@"stable"] boolValue] != stable) continue;
        } else {
            if ([version[@"version"] containsString:@"beta"] == stable) continue;
        }
        [list addObject:version[@"version"]];
    }
    self.localKVO[key] = list.firstObject;
    [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:row inSection:0]] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)changeLoaderTypeTo:(int)type {
    [self changeTypeToStable:(type == 0) forList:self.loaderList fromMetadata:self.loaderMetadata atRow:4 key:@"loaderVersion"];
}

- (void)changeVersionTypeTo:(int)type {
    [self changeTypeToStable:(type == 0) forList:self.versionList fromMetadata:self.versionMetadata atRow:1 key:@"gameVersion"];
}

- (void)segmentChanged:(UISegmentedControl *)sender {
    NSDictionary *item = objc_getAssociatedObject(sender, @"item");
    self.localKVO[item[@"key"]] = [sender titleForSegmentAtIndex:sender.selectedSegmentIndex];
    self.localKVO[[NSString stringWithFormat:@"%@_index", item[@"key"]]] = @(sender.selectedSegmentIndex);
    void(^invokeAction)(int) = item[@"action"];
    if (invokeAction) {
        invokeAction(sender.selectedSegmentIndex);
    }
}

- (void)updateSearchResults {
}

@end
