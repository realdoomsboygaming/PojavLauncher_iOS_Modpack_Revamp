#import "AFNetworking.h"
#import "LauncherNavigationController.h"
#import "ModpackInstallViewController.h"
#import "UIKit+AFNetworking.h"
#import "UIKit+hook.h"
#import "WFWorkflowProgressView.h"
#import "modpack/ModrinthAPI.h"
#import "modpack/CurseForgeAPI.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#include <dlfcn.h"

#define kCurseForgeGameIDMinecraft 432
#define kCurseForgeClassIDModpack 4471
#define kCurseForgeClassIDMod 6

@interface ModpackInstallViewController () <UIContextMenuInteractionDelegate>
@property (nonatomic) UISearchController *searchController;
@property (nonatomic) UIMenu *currentMenu;
@property (nonatomic) NSMutableArray *list;
@property (nonatomic) NSMutableDictionary *filters;
@property (nonatomic, strong) ModrinthAPI *modrinth;
@property (nonatomic, strong) CurseForgeAPI *curseForge;
@property (nonatomic) UISegmentedControl *apiSegmentControl;
@end

@implementation ModpackInstallViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.navigationItem.searchController = self.searchController;
    
    self.curseForge = [[CurseForgeAPI alloc] initWithAPIKey:[self loadAPIKey]];
    self.modrinth = [ModrinthAPI new];
    
    self.apiSegmentControl = [[UISegmentedControl alloc] initWithItems:@[@"CurseForge", @"Modrinth"]];
    self.apiSegmentControl.selectedSegmentIndex = 0;
    self.apiSegmentControl.frame = CGRectMake(0, 0, 200, 30);
    [self.apiSegmentControl addTarget:self action:@selector(apiSegmentChanged:) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = self.apiSegmentControl;
    
    self.filters = [@{ @"isModpack": @(YES), @"name": @" " } mutableCopy];
    [self updateSearchResults];
}

- (NSString *)loadAPIKey {
    NSDictionary *environment = [[NSProcessInfo processInfo] environment];
    NSString *apiKey = environment[@"CURSEFORGE_API_KEY"];
    if (!apiKey || [apiKey length] == 0) {
        NSLog(@"⚠️ WARNING: CurseForge API key is missing! Add CURSEFORGE_API_KEY to environment variables.");
    }
    return apiKey;
}

- (void)apiSegmentChanged:(UISegmentedControl *)sender {
    self.list = [NSMutableArray new];
    self.curseForge.previousOffset = 0;
    [self updateSearchResults];
}

- (void)loadSearchResultsWithPrevList:(BOOL)prevList {
    NSString *name = self.searchController.searchBar.text;
    if (!prevList && [self.filters[@"name"] isEqualToString:name]) {
        return;
    }
    
    [self switchToLoadingState];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        self.filters[@"name"] = name;
        if (self.apiSegmentControl.selectedSegmentIndex == 0) {
            self.list = [self.curseForge searchModWithFilters:self.filters previousPageResult:prevList ? self.list : nil];
        } else {
            self.list = [self.modrinth searchModWithFilters:self.filters previousPageResult:prevList ? self.list : nil];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.list) {
                [self switchToReadyState];
                [self.tableView reloadData];
            } else {
                showDialog(localize(@"Error", nil),
                           self.apiSegmentControl.selectedSegmentIndex == 0 ? self.curseForge.lastError.localizedDescription : self.modrinth.lastError.localizedDescription);
                [self actionClose];
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
    UIActivityIndicatorView *indicator = (id)self.navigationItem.rightBarButtonItem.customView;
    [indicator stopAnimating];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(actionClose)];
    self.navigationController.modalInPresentation = NO;
    self.tableView.allowsSelection = YES;
}

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
    [cell.imageView setImageWithURL:[NSURL URLWithString:item[@"imageUrl"]] placeholderImage:fallbackImage];
    
    if ((self.apiSegmentControl.selectedSegmentIndex == 0 && !self.curseForge.reachedLastPage) ||
        (self.apiSegmentControl.selectedSegmentIndex == 1 && !self.modrinth.reachedLastPage)) {
        if (indexPath.row == self.list.count - 1) {
            [self loadSearchResultsWithPrevList:YES];
        }
    }
    
    return cell;
}

@end
