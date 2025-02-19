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
#include <dlfcn.h>

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
    
    // Initialize Modrinth API normally.
    self.modrinth = [ModrinthAPI new];
    
    // If an API key is already saved, initialize the CurseForgeAPI.
    NSString *key = [self loadAPIKey];
    if (key.length > 0) {
        self.curseForge = [[CurseForgeAPI alloc] initWithAPIKey:key];
    }
    
    self.apiSegmentControl = [[UISegmentedControl alloc] initWithItems:@[@"CurseForge", @"Modrinth"]];
    self.apiSegmentControl.selectedSegmentIndex = 0;
    self.apiSegmentControl.frame = CGRectMake(0, 0, 200, 30);
    [self.apiSegmentControl addTarget:self action:@selector(apiSegmentChanged:) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = self.apiSegmentControl;
    
    self.filters = [@{ @"isModpack": @(YES), @"name": @" " } mutableCopy];
    [self updateSearchResults];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    NSString *key = [self loadAPIKey];
    if (!key || key.length == 0) {
        [self promptForAPIKey];
    }
}

- (NSString *)loadAPIKey {
    return [[NSUserDefaults standardUserDefaults] stringForKey:@"CURSEFORGE_API_KEY"];
}

- (void)promptForAPIKey {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Enter API Key" message:@"Please enter your CurseForge API key:" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"API Key";
        // Optionally set secureTextEntry if you want to hide input:
        textField.secureTextEntry = YES;
    }];
    
    UIAlertAction *saveAction = [UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        UITextField *keyField = alert.textFields.firstObject;
        NSString *enteredKey = keyField.text;
        if (enteredKey.length > 0) {
            [[NSUserDefaults standardUserDefaults] setObject:enteredKey forKey:@"CURSEFORGE_API_KEY"];
            [[NSUserDefaults standardUserDefaults] synchronize];
            self.curseForge = [[CurseForgeAPI alloc] initWithAPIKey:enteredKey];
            // Optionally refresh search results after key is saved.
            [self updateSearchResults];
        } else {
            // If empty, prompt again.
            [self promptForAPIKey];
        }
    }];
    
    [alert addAction:saveAction];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)apiSegmentChanged:(UISegmentedControl *)sender {
    self.list = [NSMutableArray new];
    self.curseForge.previousOffset = 0;
    [self updateSearchResults];
}

- (void)updateSearchResults {
    [self loadSearchResultsWithPrevList:NO];
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

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
        return self.currentMenu;
    }];
}

@end
