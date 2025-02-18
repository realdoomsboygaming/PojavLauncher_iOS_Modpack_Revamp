#import "AFNetworking.h"
#import "LauncherNavigationController.h"
#import "ModpackInstallViewController.h"
#import "UIKit+AFNetworking.h"
#import "UIKit+hook.h"
#import "WFWorkflowProgressView.h"
#import "modpack/ModrinthAPI.h"
#import "modpack/CurseForgeAPI.h"
#import "config.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#include <dlfcn.h>
#import <SDWebImage/UIImageView+WebCache.h>

#define kCurseForgeGameIDMinecraft 432
#define kCurseForgeClassIDModpack 4471
#define kCurseForgeClassIDMod 6

@interface ModpackInstallViewController () <UIContextMenuInteractionDelegate, UISearchResultsUpdating, UITableViewDataSource, UITableViewDelegate>
@property(nonatomic) UISearchController *searchController;
@property(nonatomic) UISegmentedControl *sourceSegmentedControl;
@property(nonatomic) UIMenu *currentMenu;
@property(nonatomic) NSMutableArray *list;
@property(nonatomic) NSMutableDictionary *filters;
@property (nonatomic, strong) ModrinthAPI *modrinth;
@property (nonatomic, strong) CurseForgeAPI *curseForge;
@end

@implementation ModpackInstallViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.navigationItem.searchController = self.searchController;
    
    self.sourceSegmentedControl = [[UISegmentedControl alloc] initWithItems:@[@"Modrinth", @"CurseForge"]];
    self.sourceSegmentedControl.selectedSegmentIndex = 0;
    [self.sourceSegmentedControl addTarget:self action:@selector(sourceChanged:) forControlEvents:UIControlEventValueChanged];
    self.tableView.tableHeaderView = self.sourceSegmentedControl;
    
    self.modrinth = [ModrinthAPI new];
    self.curseForge = [[CurseForgeAPI alloc] initWithAPIKey:CONFIG_CURSEFORGE_API_KEY];
    
    self.filters = [@{
        @"isModpack": @(YES),
        @"name": @" "
    } mutableCopy];
    
    [self updateSearchResults];
}

#pragma mark - Search / Filtering

- (void)loadSearchResultsWithPrevList:(BOOL)prevList {
    NSString *name = self.searchController.searchBar.text;
    if (!prevList && [self.filters[@"name"] isEqualToString:name]) {
        return;
    }
    [self switchToLoadingState];
    self.filters[@"name"] = name;
    
    if (self.sourceSegmentedControl.selectedSegmentIndex == 0) {
        self.list = [self.modrinth searchModWithFilters:self.filters previousPageResult:prevList ? self.list : nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self switchToReadyState];
            [self.tableView reloadData];
        });
    } else {
        [self.curseForge searchModsWithFilters:self.filters previousPageResult:prevList ? self.list : nil completion:^(NSArray *results, BOOL hasMore, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (results) {
                    self.list = [NSMutableArray arrayWithArray:results];
                    [self switchToReadyState];
                    [self.tableView reloadData];
                } else {
                    showDialog(localize(@"Error", nil), error.localizedDescription);
                    [self actionClose];
                }
            });
        }];
    }
}

- (void)updateSearchResults {
    [self loadSearchResultsWithPrevList:NO];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateSearchResults) object:nil];
    [self performSelector:@selector(updateSearchResults) withObject:nil afterDelay:0.5];
}

#pragma mark - UI Actions

- (void)sourceChanged:(UISegmentedControl *)sender {
    self.list = [NSMutableArray array];
    [self updateSearchResults];
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

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.list.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
        cell.imageView.contentMode = UIViewContentModeScaleToFill;
        cell.imageView.clipsToBounds = YES;
    }
    
    NSDictionary *item = self.list[indexPath.row];
    cell.textLabel.text = item[@"title"];
    cell.detailTextLabel.text = item[@"description"];
    
    UIImage *fallbackImage = [UIImage imageNamed:@"DefaultProfile"];
    [cell.imageView sd_setImageWithURL:[NSURL URLWithString:item[@"imageUrl"]] placeholderImage:fallbackImage];
    
    if (self.sourceSegmentedControl.selectedSegmentIndex == 0 && !self.modrinth.reachedLastPage && indexPath.row == self.list.count - 1) {
        [self loadSearchResultsWithPrevList:YES];
    }
    
    return cell;
}

#pragma mark - Table View Details & Selection

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
            if (self.sourceSegmentedControl.selectedSegmentIndex == 0) {
                [self.modrinth installModpackFromDetail:self.list[indexPath.row] atIndex:i];
            } else {
                [self.curseForge installModpackFromDetail:self.list[indexPath.row] atIndex:i completion:^(BOOL success, NSError *error) {
                    if (!success) {
                        showDialog(localize(@"Error", nil), error.localizedDescription);
                    }
                }];
            }
        }]];
    }];
    
    self.currentMenu = [UIMenu menuWithTitle:@"" children:menuItems];
    UIContextMenuInteraction *interaction = [[UIContextMenuInteraction alloc] initWithDelegate:self];
    cell.detailTextLabel.interactions = @[interaction];
    [interaction _presentMenuAtLocation:CGPointZero];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
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
        } else {
            [self.curseForge getModDetails:item[@"id"] completion:^(NSDictionary *details, NSError *error) {
                if (!error) {
                    NSMutableDictionary *updatedItem = [item mutableCopy];
                    [updatedItem addEntriesFromDictionary:details];
                    self.list[indexPath.row] = updatedItem;
                }
            }];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self switchToReadyState];
            NSDictionary *updatedItem = self.list[indexPath.row];
            if ([updatedItem[@"versionDetailsLoaded"] boolValue]) {
                [self showDetails:updatedItem atIndexPath:indexPath];
            } else {
                if (self.sourceSegmentedControl.selectedSegmentIndex == 0) {
                    showDialog(localize(@"Error", nil), self.modrinth.lastError.localizedDescription);
                } else {
                    showDialog(localize(@"Error", nil), @"Failed to load mod details from CurseForge.");
                }
            }
        });
    });
}

@end
