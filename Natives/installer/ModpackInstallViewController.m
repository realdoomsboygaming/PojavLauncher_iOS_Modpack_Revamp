#import "AFNetworking.h"
#import "LauncherNavigationController.h"
#import "ModpackInstallViewController.h"
#import "UIKit+AFNetworking.h"
#import "UIKit+hook.h"
#import "WFWorkflowProgressView.h"
#import "modpack/ModrinthAPI.h"
#import "modpack/CurseForgeAPI.h"
#import "ModMenuViewController.h"
#import "config.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import "PLProfiles.h"
#import "modpack/ModpackUtils.h"
#include <dlfcn.h>

@interface ModpackInstallViewController () <UIContextMenuInteractionDelegate>
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) UISegmentedControl *sourceSegmentedControl;
@property (nonatomic, strong) UIMenu *currentMenu;
@property (nonatomic, strong) NSMutableArray *list;
@property (nonatomic, strong) NSMutableDictionary *filters;
@property (nonatomic, strong) ModrinthAPI *modrinth;
@property (nonatomic, strong) CurseForgeAPI *curseForge;
@property (nonatomic, strong) NSString *selectedProfileName;
@end

@implementation ModpackInstallViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.navigationItem.searchController = self.searchController;
    
    self.modrinth = [ModrinthAPI new];
    self.curseForge = [[CurseForgeAPI alloc] initWithAPIKey:(CONFIG_CURSEFORGE_API_KEY ?: @"")];
    self.filters = [@{@"isModpack": @(YES), @"name": @" "} mutableCopy];
    
    self.sourceSegmentedControl = [[UISegmentedControl alloc] initWithItems:@[@"Modrinth", @"CurseForge", @"Profiles"]];
    self.sourceSegmentedControl.selectedSegmentIndex = 0;
    [self.sourceSegmentedControl addTarget:self action:@selector(updateSearchResults) forControlEvents:UIControlEventValueChanged];
    UIView *headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.frame.size.width, 44)];
    self.sourceSegmentedControl.frame = CGRectMake(10, 5, headerView.frame.size.width - 20, 34);
    [headerView addSubview:self.sourceSegmentedControl];
    self.tableView.tableHeaderView = headerView;
    
    [self updateSearchResults];
}

- (void)updateSearchResults {
    [self loadCurrentSourceResultsWithPrevList:NO];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateSearchResults) object:nil];
    [self performSelector:@selector(updateSearchResults) withObject:nil afterDelay:0.5];
}

- (void)loadCurrentSourceResultsWithPrevList:(BOOL)prevList {
    NSInteger index = self.sourceSegmentedControl.selectedSegmentIndex;
    if (index == 0) {
        [self loadModrinthResultsWithPrevList:prevList];
    } else if (index == 1) {
        [self loadCurseForgeResultsWithPrevList:prevList];
    } else if (index == 2) {
        [self loadProfiles];
    }
}

- (void)loadModrinthResultsWithPrevList:(BOOL)prevList {
    NSString *name = self.searchController.searchBar.text;
    if (!prevList && [self.filters[@"name"] isEqualToString:name]) {
        return;
    }
    [self switchToLoadingState];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        self.filters[@"name"] = name;
        self.list = [self.modrinth searchModWithFilters:self.filters previousPageResult:prevList ? self.list : nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.list) {
                [self switchToReadyState];
                [self.tableView reloadData];
            } else {
                showDialog(localize(@"Error", nil), self.modrinth.lastError.localizedDescription);
                [self actionClose];
            }
        });
    });
}

- (void)loadCurseForgeResultsWithPrevList:(BOOL)prevList {
    NSString *name = self.searchController.searchBar.text;
    [self switchToLoadingState];
    [self.curseForge searchModWithFilters:self.filters previousPageResult:prevList ? self.list : nil completion:^(NSMutableArray *results, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (results) {
                self.list = results;
                [self switchToReadyState];
                [self.tableView reloadData];
            } else {
                showDialog(localize(@"Error", nil), error.localizedDescription);
                [self actionClose];
            }
        });
    }];
}

- (void)loadProfiles {
    NSDictionary *profilesDict = PLProfiles.current.profiles;
    self.list = [[profilesDict allValues] mutableCopy];
    [self.list sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] compare:b[@"name"]];
    }];
    [self.tableView reloadData];
}

- (void)actionClose {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (void)switchToLoadingState {
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:indicator];
    [indicator startAnimating];
    self.navigationController.modalInPresentation = YES;
    self.tableView.allowsSelection = NO;
}

- (void)switchToReadyState {
    UIActivityIndicatorView *indicator = (id)self.navigationItem.rightBarButtonItem.customView;
    [indicator stopAnimating];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(actionClose)];
    self.navigationController.modalInPresentation = NO;
    self.tableView.allowsSelection = YES;
}

#pragma mark - UIContextMenu

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu * _Nullable(NSArray<UIMenuElement *> * _Nonnull suggestedActions) {
        return self.currentMenu;
    }];
}

- (_UIContextMenuStyle *)_contextMenuInteraction:(UIContextMenuInteraction *)interaction styleForMenuWithConfiguration:(UIContextMenuConfiguration *)configuration {
    _UIContextMenuStyle *style = [_UIContextMenuStyle defaultStyle];
    style.preferredLayout = 3;
    return style;
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.list.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger segIndex = self.sourceSegmentedControl.selectedSegmentIndex;
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
        cell.imageView.contentMode = UIViewContentModeScaleToFill;
        cell.imageView.clipsToBounds = YES;
    }
    
    if (segIndex == 2) {
        NSDictionary *profile = self.list[indexPath.row];
        cell.textLabel.text = profile[@"name"];
        cell.detailTextLabel.text = profile[@"lastVersionId"];
        cell.imageView.image = [UIImage imageNamed:@"DefaultProfile"];
    } else {
        NSDictionary *item = self.list[indexPath.row];
        cell.textLabel.text = item[@"title"];
        cell.detailTextLabel.text = item[@"description"];
        UIImage *fallbackImage = [UIImage imageNamed:@"DefaultProfile"];
        [cell.imageView setImageWithURL:[NSURL URLWithString:item[@"imageUrl"]] placeholderImage:fallbackImage];
        if (!((segIndex == 0 ? self.modrinth : self.curseForge).reachedLastPage) && indexPath.row == self.list.count - 1) {
            [self loadCurrentSourceResultsWithPrevList:YES];
        }
    }
    return cell;
}

- (void)showDetails:(NSDictionary *)details atIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
    NSMutableArray<UIAction *> *menuItems = [[NSMutableArray alloc] init];
    [details[@"versionNames"] enumerateObjectsUsingBlock:^(NSString *name, NSUInteger i, BOOL *stop) {
        NSString *nameWithVersion = name;
        NSString *mcVersion = details[@"mcVersionNames"][i];
        if (![name hasSuffix:mcVersion]) {
            nameWithVersion = [NSString stringWithFormat:@"%@ - %@", name, mcVersion];
        }
        [menuItems addObject:[UIAction actionWithTitle:nameWithVersion image:nil identifier:nil handler:^(UIAction *action) {
            [self actionClose];
            NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
            [UIImagePNGRepresentation([cell.imageView.image _imageWithSize:CGSizeMake(40, 40)]) writeToFile:tmpIconPath atomically:YES];
            if (self.selectedProfileName) {
                [self addMod:details atVersion:i toProfile:self.selectedProfileName];
            } else {
                if (self.sourceSegmentedControl.selectedSegmentIndex == 0) {
                    [self.modrinth installModpackFromDetail:self.list[indexPath.row] atIndex:i];
                } else if (self.sourceSegmentedControl.selectedSegmentIndex == 1) {
                    [self.curseForge installModpackFromDetail:self.list[indexPath.row] atIndex:i completion:^(NSError *error) {
                        if (error) {
                            showDialog(localize(@"Error", nil), error.localizedDescription);
                        }
                    }];
                }
            }
        }]];
    }];
    self.currentMenu = [UIMenu menuWithTitle:@"" children:menuItems];
    UIContextMenuInteraction *interaction = [[UIContextMenuInteraction alloc] initWithDelegate:self];
    cell.detailTextLabel.interactions = @[interaction];
    [interaction _presentMenuAtLocation:CGPointZero];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSInteger segIndex = self.sourceSegmentedControl.selectedSegmentIndex;
    if (segIndex == 2) {
        NSDictionary *profile = self.list[indexPath.row];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Add Mod" message:@"Choose a mod source" preferredStyle:UIAlertControllerStyleActionSheet];
        [alert addAction:[UIAlertAction actionWithTitle:@"Modrinth" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            self.selectedProfileName = profile[@"name"];
            self.sourceSegmentedControl.selectedSegmentIndex = 0;
            [self updateSearchResults];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"CurseForge" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            self.selectedProfileName = profile[@"name"];
            self.sourceSegmentedControl.selectedSegmentIndex = 1;
            [self updateSearchResults];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Mods" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            ModMenuViewController *modMenuVC = [[ModMenuViewController alloc] init];
            modMenuVC.title = @"Mods";
            [self.navigationController pushViewController:modMenuVC animated:YES];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    
    NSDictionary *item = self.list[indexPath.row];
    if ([item[@"versionDetailsLoaded"] boolValue]) {
        [self showDetails:item atIndexPath:indexPath];
        return;
    }
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    [self switchToLoadingState];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (self.sourceSegmentedControl.selectedSegmentIndex == 0) {
            [self.modrinth loadDetailsOfMod:self.list[indexPath.row]];
        } else if (self.sourceSegmentedControl.selectedSegmentIndex == 1) {
            [self.curseForge loadDetailsOfMod:self.list[indexPath.row] completion:^(NSError *error) {
            }];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self switchToReadyState];
            if ([item[@"versionDetailsLoaded"] boolValue]) {
                [self showDetails:item atIndexPath:indexPath];
            } else {
                NSString *errorMsg = self.sourceSegmentedControl.selectedSegmentIndex == 0 ? self.modrinth.lastError.localizedDescription : self.curseForge.lastError.localizedDescription;
                showDialog(localize(@"Error", nil), errorMsg);
            }
        });
    });
}

- (void)addMod:(NSDictionary *)modDetail atVersion:(NSUInteger)versionIndex toProfile:(NSString *)profileName {
    NSMutableDictionary *profile = [PLProfiles.current.profiles[profileName] mutableCopy];
    if (!profile) return;
    NSMutableArray *mods = profile[@"mods"];
    if (!mods) { mods = [NSMutableArray new]; }
    NSDictionary *modEntry = @{@"modDetail": modDetail, @"selectedVersion": @(versionIndex)};
    [mods addObject:modEntry];
    profile[@"mods"] = mods;
    PLProfiles.current.profiles[profileName] = profile;
    [PLProfiles.current save];
    self.selectedProfileName = nil;
    showDialog(@"Success", @"Mod added to profile.");
}

@end

