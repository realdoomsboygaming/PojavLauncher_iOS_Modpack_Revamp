#import "ModpackInstallViewController.h"
#import "LauncherNavigationController.h"
#import "WFWorkflowProgressView.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import "config.h"

// Note: Because this file is in Natives/installer and the API files are in the modpack subfolder,
// import using the relative path. Alternatively, update your Header Search Paths.
#import "modpack/CurseForgeAPI.h"
#import "modpack/ModrinthAPI.h"

@interface ModpackInstallViewController () <UITableViewDelegate, UITableViewDataSource, UISearchResultsUpdating, UIContextMenuInteractionDelegate>

// We hold a strong reference to the table view as a separate property
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIImage *fallbackImage;

@end

@implementation ModpackInstallViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // Initialize TableView as a separate object, then add it to self.view
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.tableView];
    
    // Configure Search Controller
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    
    // If you support iOS 11+ and above, you can attach it to navigationItem like this:
    // For iOS 14 compatibility, this is fine since iOS 14 >= 11.
    self.navigationItem.searchController = self.searchController;

    // Initialize APIs
    self.modrinth = [ModrinthAPI new];
    NSString *key = [[NSUserDefaults standardUserDefaults] stringForKey:@"CURSEFORGE_API_KEY"];
    if (key.length > 0) {
        self.curseForge = [[CurseForgeAPI alloc] initWithAPIKey:key];
    }
    
    // Configure Segmented Control
    self.apiSegmentControl = [[UISegmentedControl alloc] initWithItems:@[@"CurseForge", @"Modrinth"]];
    self.apiSegmentControl.selectedSegmentIndex = 0;
    self.apiSegmentControl.frame = CGRectMake(0, 0, 200, 30);
    [self.apiSegmentControl addTarget:self
                               action:@selector(apiSegmentChanged:)
                     forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = self.apiSegmentControl;
    
    // Initialize Filters
    self.filters = [@{@"isModpack": @(YES), @"name": @""} mutableCopy];
    self.fallbackImage = [UIImage imageNamed:@"DefaultProfile"];
    
    // First load
    [self updateSearchResults];
}

#pragma mark - Segment Control Handler

- (void)apiSegmentChanged:(UISegmentedControl *)sender {
    [self.list removeAllObjects];
    [self.tableView reloadData];
    [self updateSearchResults];
}

#pragma mark - Context Menu Delegate

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction
                         configurationForMenuAtLocation:(CGPoint)location
{
    // Return a configuration that yields self.currentMenu
    return [UIContextMenuConfiguration
        configurationWithIdentifier:nil
        previewProvider:nil
        actionProvider:^UIMenu * _Nullable(NSArray<UIMenuElement *> * _Nonnull suggestedActions) {
            return self.currentMenu;
        }];
}

#pragma mark - TableView Delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self showDetails:self.list[indexPath.row] atIndexPath:indexPath];
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
          contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
                                              point:(CGPoint)point
{
    return [UIContextMenuConfiguration
        configurationWithIdentifier:nil
        previewProvider:nil
        actionProvider:^UIMenu * _Nullable(NSArray<UIMenuElement *> * _Nonnull suggestedActions) {
            return self.currentMenu;
        }];
}

#pragma mark - Search Handling

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [NSObject cancelPreviousPerformRequestsWithTarget:self
                                             selector:@selector(updateSearchResults)
                                               object:nil];
    [self performSelector:@selector(updateSearchResults)
               withObject:nil
               afterDelay:0.5];
}

- (void)updateSearchResults {
    [self loadSearchResultsWithPrevList:NO];
}

- (void)loadSearchResultsWithPrevList:(BOOL)prevList {
    NSString *name = self.searchController.searchBar.text;
    // Ensure filters[@"name"] is a valid string (default to empty string if not)
    NSString *previousName = ([self.filters[@"name"] isKindOfClass:[NSString class]] ? self.filters[@"name"] : @"");
    if (!prevList && [previousName isEqualToString:name]) return;
    
    [self switchToLoadingState];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        self.filters[@"name"] = name;
        NSError *searchError = nil;
        NSMutableArray *results = nil;
        
        if (self.apiSegmentControl.selectedSegmentIndex == 0) {
            // Searching with CurseForge
            results = [self.curseForge searchModWithFilters:self.filters
                                         previousPageResult:prevList ? self.list : nil];
            searchError = self.curseForge.lastError;
        } else {
            // Searching with Modrinth
            results = [self.modrinth searchModWithFilters:self.filters
                                       previousPageResult:prevList ? self.list : nil];
            searchError = self.modrinth.lastError;
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (results) {
                self.list = results;
                [self.tableView reloadData];
            } else {
                showDialog(localize(@"Error", nil), searchError.localizedDescription);
            }
            [self switchToReadyState];
        });
    });
}

#pragma mark - TableView DataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.list.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"cell"];
        cell.imageView.contentMode = UIViewContentModeScaleAspectFit;
        cell.imageView.clipsToBounds = YES;
        
        // Add context menu interaction to new cells (iOS 13+, so iOS 14 is fine)
        UIContextMenuInteraction *interaction = [[UIContextMenuInteraction alloc] initWithDelegate:self];
        [cell addInteraction:interaction];
    }
    
    NSDictionary *item = self.list[indexPath.row];
    cell.textLabel.text = ([item[@"title"] isKindOfClass:[NSString class]] ? item[@"title"] : @"Untitled");
    cell.detailTextLabel.text = ([item[@"description"] isKindOfClass:[NSString class]] ? item[@"description"] : @"No description");
    
    // Image Loading
    NSString *imageUrl = ([item[@"imageUrl"] isKindOfClass:[NSString class]] ? item[@"imageUrl"] : @"");
    if (imageUrl.length > 0) {
        [self loadImageForCell:cell withURL:imageUrl];
    } else {
        cell.imageView.image = self.fallbackImage;
    }
    
    // Pagination
    BOOL usingCurseForge = (self.apiSegmentControl.selectedSegmentIndex == 0);
    BOOL reachedLastPage = usingCurseForge ? self.curseForge.reachedLastPage : self.modrinth.reachedLastPage;
    if (!reachedLastPage && indexPath.row == self.list.count - 1) {
        [self loadSearchResultsWithPrevList:YES];
    }
    
    return cell;
}

#pragma mark - Context Menu Handling

- (void)showDetails:(NSDictionary *)details atIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Select Version"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    NSArray *versionNames = details[@"versionNames"];
    NSArray *mcVersionNames = details[@"mcVersionNames"];
    
    if (![versionNames isKindOfClass:[NSArray class]] ||
        ![mcVersionNames isKindOfClass:[NSArray class]]) {
        return;
    }
    
    [versionNames enumerateObjectsUsingBlock:^(NSString *name, NSUInteger i, BOOL *stop) {
        NSString *mcVersion = (mcVersionNames.count > i ? mcVersionNames[i] : @"");
        NSString *nameWithVersion = ([name containsString:mcVersion]
                                     ? name
                                     : [NSString stringWithFormat:@"%@ - %@", name, mcVersion]);
        
        UIAlertAction *versionAction = [UIAlertAction actionWithTitle:nameWithVersion
                                                                style:UIAlertActionStyleDefault
                                                              handler:^(UIAlertAction * _Nonnull action)
        {
            // Save the image from the cell.
            NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
            NSData *imageData = UIImagePNGRepresentation(cell.imageView.image);
            [imageData writeToFile:tmpIconPath atomically:YES];
            
            // Install modpack using the appropriate API
            if (self.apiSegmentControl.selectedSegmentIndex == 0) {
                [self.curseForge installModpackFromDetail:self.list[indexPath.row]
                                                   atIndex:i];
            } else {
                [self.modrinth installModpackFromDetail:self.list[indexPath.row]
                                                 atIndex:i];
            }
            [self actionClose];
        }];
        
        [alert addAction:versionAction];
    }];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    
    // Required on iPad; also helpful on iPhone if using a popover style
    if (alert.popoverPresentationController) {
        alert.popoverPresentationController.sourceView = cell;
        alert.popoverPresentationController.sourceRect = cell.bounds;
        alert.popoverPresentationController.permittedArrowDirections = UIPopoverArrowDirectionAny;
    }
    
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - UI State Management

- (void)switchToLoadingState {
    UIActivityIndicatorView *indicator =
      [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [indicator startAnimating];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:indicator];
    
    // modalInPresentation is iOS 13+, so iOS 14 is definitely okay
    self.navigationController.modalInPresentation = YES;
    self.tableView.allowsSelection = NO;
}

- (void)switchToReadyState {
    // Restore the bar button item to a close button (iOS 13+ for the .Close system item)
    UIActivityIndicatorView *indicator = (id)self.navigationItem.rightBarButtonItem.customView;
    [indicator stopAnimating];
    
    self.navigationItem.rightBarButtonItem =
      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                    target:self
                                                    action:@selector(actionClose)];
    
    self.navigationController.modalInPresentation = NO;
    self.tableView.allowsSelection = YES;
}

- (void)actionClose {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Image Loading

- (void)loadImageForCell:(UITableViewCell *)cell withURL:(NSString *)urlString {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return;
    
    NSURLSessionDataTask *task =
      [[NSURLSession sharedSession] dataTaskWithURL:url
                                  completionHandler:^(NSData *data,
                                                      NSURLResponse *response,
                                                      NSError *error)
    {
        if (!error && data) {
            UIImage *downloadedImage = [UIImage imageWithData:data];
            dispatch_async(dispatch_get_main_queue(), ^{
                cell.imageView.image = downloadedImage ?: self.fallbackImage;
                [cell setNeedsLayout];
            });
        }
    }];
    [task resume];
}

@end
