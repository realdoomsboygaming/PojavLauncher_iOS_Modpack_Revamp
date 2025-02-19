#import "LauncherNavigationController.h"
#import "ModpackInstallViewController.h"
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
@property (nonatomic, strong) UIImage *fallbackImage;
@end

@implementation ModpackInstallViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // Initialize TableView
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tableView];
    
    // Initialize Search Controller
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.navigationItem.searchController = self.searchController;
    
    // Initialize APIs
    self.modrinth = [ModrinthAPI new];
    NSString *key = [self loadAPIKey];
    if (key.length > 0) {
        self.curseForge = [[CurseForgeAPI alloc] initWithAPIKey:key];
    }
    
    // Configure Segmented Control
    self.apiSegmentControl = [[UISegmentedControl alloc] initWithItems:@[@"CurseForge", @"Modrinth"]];
    self.apiSegmentControl.selectedSegmentIndex = 0;
    self.apiSegmentControl.frame = CGRectMake(0, 0, 200, 30);
    [self.apiSegmentControl addTarget:self action:@selector(apiSegmentChanged:) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = self.apiSegmentControl;
    
    // Initialize Filters
    self.filters = [@{ 
        @"isModpack": @(YES), 
        @"name": @"" // Changed from @" " to empty string
    } mutableCopy];
    
    // Load initial data
    [self updateSearchResults];
    
    // Preload fallback image
    self.fallbackImage = [UIImage imageNamed:@"DefaultProfile"];
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
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"API Key";
        textField.secureTextEntry = YES;
    }];
    
    UIAlertAction *saveAction = [UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        UITextField *keyField = alert.textFields.firstObject;
        NSString *enteredKey = keyField.text;
        if (enteredKey.length > 0) {
            [[NSUserDefaults standardUserDefaults] setObject:enteredKey forKey:@"CURSEFORGE_API_KEY"];
            [[NSUserDefaults standardUserDefaults] synchronize];
            self.curseForge = [[CurseForgeAPI alloc] initWithAPIKey:enteredKey];
            [self updateSearchResults];
        } else {
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
        
        NSError *searchError = nil;
        NSMutableArray *results = nil;
        
        if (self.apiSegmentControl.selectedSegmentIndex == 0) {
            results = [self.curseForge searchModWithFilters:self.filters previousPageResult:prevList ? self.list : nil];
            searchError = self.curseForge.lastError;
        } else {
            results = [self.modrinth searchModWithFilters:self.filters previousPageResult:prevList ? self.list : nil];
            searchError = self.modrinth.lastError;
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (results) {
                self.list = results;
                [self.tableView reloadData];
            } else {
                NSLog(@"[ERROR] Search failed: %@", searchError.localizedDescription);
                showDialog(localize(@"Error", nil), searchError.localizedDescription);
            }
            [self switchToReadyState];
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
        cell.imageView.contentMode = UIViewContentModeScaleAspectFit;
        cell.imageView.clipsToBounds = YES;
        cell.imageView.frame = CGRectMake(0, 0, 60, 60); // Fixed image size
    }
    
    NSDictionary *item = self.list[indexPath.row];
    cell.textLabel.text = item[@"title"] ?: @"Untitled";
    cell.detailTextLabel.text = item[@"description"] ?: @"No description";
    cell.detailTextLabel.numberOfLines = 2;
    
    // Async image loading with native NSURLSession
    NSString *imageUrl = item[@"imageUrl"];
    if (imageUrl.length > 0) {
        [self loadImageForCell:cell withURL:imageUrl];
    } else {
        cell.imageView.image = self.fallbackImage;
    }
    
    // Pagination
    if ((self.apiSegmentControl.selectedSegmentIndex == 0 && !self.curseForge.reachedLastPage) ||
        (self.apiSegmentControl.selectedSegmentIndex == 1 && !self.modrinth.reachedLastPage)) {
        if (indexPath.row == self.list.count - 1) {
            [self loadSearchResultsWithPrevList:YES];
        }
    }
    
    return cell;
}

- (void)loadImageForCell:(UITableViewCell *)cell withURL:(NSString *)urlString {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return;
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) return;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            UIImage *image = [UIImage imageWithData:data];
            cell.imageView.image = image ?: self.fallbackImage;
            [cell setNeedsLayout];
        });
    }];
    [task resume];
}

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction configurationForMenuAtLocation:(CGPoint)location {
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
        return self.currentMenu;
    }];
}

@end
