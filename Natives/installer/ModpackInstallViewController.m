#import "AFNetworking.h"
#import "LauncherNavigationController.h"
#import "ModpackInstallViewController.h"
#import "UIKit+AFNetworking.h"
#import "UIKit+hook.h"
#import "WFWorkflowProgressView.h"
#import "config.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#include <dlfcn.h>

@interface ModpackInstallViewController () <UISearchResultsUpdating>

@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) NSMutableArray *list;
@property (nonatomic, strong) NSMutableDictionary *filters;

@property (nonatomic, strong) ModrinthAPI *modrinth;  // ModrinthAPI
@property (nonatomic, strong) CurseforgeAPI *curseforge;  // CurseForgeAPI

@property (nonatomic, assign) BOOL isUsingCurseForge;  // Boolean to track which API is active

@end

@implementation ModpackInstallViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.tableView.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    
    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(refreshSearchResults) forControlEvents:UIControlEventValueChanged];
    
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = @"Search Modpacks";
    self.navigationItem.searchController = self.searchController;
    
    // Initialize both APIs
    self.modrinth = [ModrinthAPI new];
    self.curseforge = [[CurseforgeAPI alloc] initWithApiKey:@"your_api_key_here"];  // Initialize with API key
    
    // Default API to use
    self.isUsingCurseForge = NO;  // Initially using Modrinth
    
    self.filters = [@{ @"isModpack": @(YES), @"name": @" " } mutableCopy];
    
    // Add a Segmented Control to switch between APIs
    [self addAPISelectionControl];
    
    [self updateSearchResults];
}

- (void)addAPISelectionControl {
    UISegmentedControl *apiSwitch = [[UISegmentedControl alloc] initWithItems:@[@"Modrinth", @"CurseForge"]];
    apiSwitch.selectedSegmentIndex = self.isUsingCurseForge ? 1 : 0;
    [apiSwitch addTarget:self action:@selector(apiSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = apiSwitch;
}

- (void)apiSwitchChanged:(UISegmentedControl *)sender {
    self.isUsingCurseForge = sender.selectedSegmentIndex == 1;
    [self updateSearchResults];  // Update the search results when the API is switched
}

- (void)refreshSearchResults {
    [self loadSearchResultsWithPrevList:NO];
}

- (void)loadSearchResultsWithPrevList:(BOOL)prevList {
    NSString *name = self.searchController.searchBar.text;
    if (!prevList && [self.filters[@"name"] isEqualToString:name]) return;
    
    [self switchToLoadingState];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        self.filters[@"name"] = name;
        
        // Use the correct API based on the selection
        if (self.isUsingCurseForge) {
            self.list = [self.curseforge searchModWithFilters:self.filters previousPageResult:(prevList ? self.list : nil)];
        } else {
            self.list = [self.modrinth searchModWithFilters:self.filters previousPageResult:(prevList ? self.list : nil)];
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.list) {
                [self switchToReadyState];
                [self.tableView reloadData];
            } else {
                showDialog(@"Error", self.isUsingCurseForge ? self.curseforge.lastError.localizedDescription : self.modrinth.lastError.localizedDescription);
                [self actionClose];
            }
            if (self.refreshControl.isRefreshing) {
                [self.refreshControl endRefreshing];
            }
        });
    });
}

- (void)updateSearchResults {
    [self loadSearchResultsWithPrevList:NO];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateSearchResults) object:nil];
    [self performSelector:@selector(updateSearchResults) withObject:nil afterDelay:0.5];
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
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(actionClose)];
    self.navigationController.modalInPresentation = NO;
    self.tableView.allowsSelection = YES;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.list.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ModpackCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"ModpackCell"];
    }
    
    NSDictionary *item = self.list[indexPath.row];
    cell.textLabel.text = item[@"title"];
    cell.detailTextLabel.text = item[@"description"];
    [cell.imageView setImageWithURL:[NSURL URLWithString:item[@"imageUrl"]] placeholderImage:[UIImage imageNamed:@"DefaultProfile"]];
    
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *item = self.list[indexPath.row];
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    [self switchToLoadingState];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        if (self.isUsingCurseForge) {
            [self.curseforge loadModDetails:item completion:^(NSDictionary *modDetails) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self switchToReadyState];
                    if (modDetails) {
                        [self presentVersionOptionsForItem:item atIndexPath:indexPath modDetails:modDetails];
                    } else {
                        showDialog(@"Error", self.curseforge.lastError.localizedDescription);
                    }
                });
            }];
        } else {
            [self.modrinth loadModDetails:item completion:^(NSDictionary *modDetails) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self switchToReadyState];
                    if (modDetails) {
                        [self presentVersionOptionsForItem:item atIndexPath:indexPath modDetails:modDetails];
                    } else {
                        showDialog(@"Error", self.modrinth.lastError.localizedDescription);
                    }
                });
            }];
        }
    });
}

- (void)presentVersionOptionsForItem:(NSDictionary *)item atIndexPath:(NSIndexPath *)indexPath modDetails:(NSDictionary *)modDetails {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:item[@"title"] message:@"Select a version to install" preferredStyle:UIAlertControllerStyleActionSheet];
    
    NSArray *versionNames = modDetails[@"versionNames"];
    for (NSString *versionName in versionNames) {
        UIAlertAction *action = [UIAlertAction actionWithTitle:versionName style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [self actionClose];
            if (self.isUsingCurseForge) {
                [self.curseforge downloadModpack:item atVersion:versionName completion:^(BOOL success, NSError *error) {
                    if (success) {
                        // Handle success
                    } else {
                        // Handle error
                        showDialog(@"Error", error.localizedDescription);
                    }
                }];
            } else {
                [self.modrinth downloadModpack:item atVersion:versionName completion:^(BOOL success, NSError *error) {
                    if (success) {
                        // Handle success
                    } else {
                        // Handle error
                        showDialog(@"Error", error.localizedDescription);
                    }
                }];
            }
        }];
        [alert addAction:action];
    }
    
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
    [alert addAction:cancel];
    
    alert.popoverPresentationController.sourceView = self.view;
    alert.popoverPresentationController.sourceRect = [self.tableView rectForRowAtIndexPath:indexPath];
    
    [self presentViewController:alert animated:YES completion:nil];
}

@end
