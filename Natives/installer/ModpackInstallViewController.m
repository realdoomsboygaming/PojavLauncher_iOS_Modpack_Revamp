#import "ModpackInstallViewController.h"
#import "LauncherNavigationController.h"
#import "WFWorkflowProgressView.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import "config.h"

// The imports below might be redundant given the .h includes, but this is okay
#import "modpack/CurseForgeAPI.h"
#import "modpack/ModrinthAPI.h"

@interface ModpackInstallViewController () <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UIImage *fallbackImage;
@end

@implementation ModpackInstallViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // We already inherit from UITableViewController,
    // so self.tableView is the main view. By default,
    // UITableViewController sets self.view = self.tableView in its init.
    // (This is how UITableViewController is designed.)
    //
    // => If you add an additional table view, or do "self.view = [UIView new]"
    //    inside a UITableViewController, you'd risk confusion or subview errors.
    //
    // So simply ensure we do NOT reassign self.view or do a second "addSubview:"
    // for that same table. We'll just configure the existing self.tableView.

    self.tableView.delegate = self;
    self.tableView.dataSource = self;

    // Create and configure a search controller
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self; // We'll handle updates
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    
    // For iOS >= 11, this is valid:
    self.navigationItem.searchController = self.searchController;
    
    // Initialize our API objects
    self.modrinth = [ModrinthAPI new];
    NSString *key = [[NSUserDefaults standardUserDefaults] stringForKey:@"CURSEFORGE_API_KEY"];
    if (key.length > 0) {
        self.curseForge = [[CurseForgeAPI alloc] initWithAPIKey:key];
    }
    
    // Segmented control for switching between CF and Modrinth
    self.apiSegmentControl = [[UISegmentedControl alloc] initWithItems:@[@"CurseForge", @"Modrinth"]];
    self.apiSegmentControl.selectedSegmentIndex = 0;
    self.apiSegmentControl.frame = CGRectMake(0, 0, 200, 30);
    [self.apiSegmentControl addTarget:self
                               action:@selector(apiSegmentChanged:)
                     forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = self.apiSegmentControl;
    
    // Set up filters
    self.filters = [@{@"isModpack": @(YES), @"name": @""} mutableCopy];
    self.fallbackImage = [UIImage imageNamed:@"DefaultProfile"];
    
    // Trigger initial search
    [self updateSearchResults];
}

#pragma mark - UISegmentedControl Action

- (void)apiSegmentChanged:(UISegmentedControl *)sender {
    [self.list removeAllObjects];
    [self.tableView reloadData];
    [self updateSearchResults];
}

#pragma mark - UISearchResultsUpdating

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

#pragma mark - Loading Search Results

- (void)loadSearchResultsWithPrevList:(BOOL)prevList {
    NSString *name = self.searchController.searchBar.text ?: @"";
    NSString *previousName = ([self.filters[@"name"] isKindOfClass:[NSString class]] ?
                              self.filters[@"name"] : @"");
    if (!prevList && [previousName isEqualToString:name]) {
        return;
    }
    
    [self switchToLoadingState];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        self.filters[@"name"] = name;
        NSError *searchError = nil;
        NSMutableArray *results = nil;
        
        if (self.apiSegmentControl.selectedSegmentIndex == 0) {
            // CurseForge
            results = [self.curseForge searchModWithFilters:self.filters
                                         previousPageResult:(prevList ? self.list : nil)];
            searchError = self.curseForge.lastError;
        } else {
            // Modrinth
            results = [self.modrinth searchModWithFilters:self.filters
                                       previousPageResult:(prevList ? self.list : nil)];
            searchError = self.modrinth.lastError;
        }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (results) {
                self.list = results;
                [self.tableView reloadData];
            } else if (searchError) {
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
        
        // Add context menu interaction (iOS 13+)
        UIContextMenuInteraction *interaction = [[UIContextMenuInteraction alloc] initWithDelegate:self];
        [cell addInteraction:interaction];
    }
    
    NSDictionary *item = self.list[indexPath.row];
    cell.textLabel.text       = ([item[@"title"] isKindOfClass:[NSString class]] ? item[@"title"] : @"Untitled");
    cell.detailTextLabel.text = ([item[@"description"] isKindOfClass:[NSString class]] ? item[@"description"] : @"No description");
    
    // Load image
    NSString *imageUrl = ([item[@"imageUrl"] isKindOfClass:[NSString class]] ? item[@"imageUrl"] : @"");
    if (imageUrl.length > 0) {
        [self loadImageForCell:cell withURL:imageUrl];
    } else {
        cell.imageView.image = self.fallbackImage;
    }
    
    // Pagination support
    BOOL usingCurseForge = (self.apiSegmentControl.selectedSegmentIndex == 0);
    BOOL reachedLastPage = usingCurseForge ? self.curseForge.reachedLastPage
                                           : self.modrinth.reachedLastPage;
    if (!reachedLastPage && indexPath.row == self.list.count - 1) {
        [self loadSearchResultsWithPrevList:YES];
    }
    
    return cell;
}

#pragma mark - TableView Delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    [self showDetails:self.list[indexPath.row] atIndexPath:indexPath];
}

#pragma mark - Context Menu (iOS 13+)

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView
   contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
                                       point:(CGPoint)point
{
    return [UIContextMenuConfiguration
        configurationWithIdentifier:nil
        previewProvider:nil
        actionProvider:^UIMenu * _Nullable(NSArray<UIMenuElement *> * _Nonnull suggestedActions)
    {
        return self.currentMenu; // Provide custom menu or dynamically build
    }];
}

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction
                         configurationForMenuAtLocation:(CGPoint)location
{
    // Return a configuration that yields self.currentMenu
    return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                     previewProvider:nil
                                                      actionProvider:^UIMenu * _Nullable(NSArray<UIMenuElement *> * _Nonnull suggestedActions)
    {
        return self.currentMenu;
    }];
}

#pragma mark - Show Details

- (void)showDetails:(NSDictionary *)details atIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Select Version"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    NSArray *versionNames = details[@"versionNames"];
    NSArray *mcVersionNames = details[@"mcVersionNames"];
    
    if (![versionNames isKindOfClass:[NSArray class]] ||
        ![mcVersionNames isKindOfClass:[NSArray class]])
    {
        return;
    }
    
    [versionNames enumerateObjectsUsingBlock:^(NSString *name, NSUInteger i, BOOL *stop) {
        NSString *mcVersion = (i < mcVersionNames.count ? mcVersionNames[i] : @"");
        NSString *nameWithVersion = ([name containsString:mcVersion]
                                     ? name
                                     : [NSString stringWithFormat:@"%@ - %@", name, mcVersion]);
        
        UIAlertAction *versionAction = [UIAlertAction actionWithTitle:nameWithVersion
                                                                style:UIAlertActionStyleDefault
                                                              handler:^(UIAlertAction * _Nonnull action)
        {
            // Save the cell image to a temp location
            NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
            NSData *imageData = UIImagePNGRepresentation(cell.imageView.image);
            [imageData writeToFile:tmpIconPath atomically:YES];
            
            // Install
            if (self.apiSegmentControl.selectedSegmentIndex == 0) {
                // CurseForge
                [self.curseForge installModpackFromDetail:self.list[indexPath.row]
                                                   atIndex:i];
            } else {
                // Modrinth
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
    
    // On iPad, need a popover anchor
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
    
    // Lock the UI so user can't close
    self.navigationController.modalInPresentation = YES; // iOS 13+
    self.tableView.allowsSelection = NO;
}

- (void)switchToReadyState {
    UIActivityIndicatorView *indicator = (id)self.navigationItem.rightBarButtonItem.customView;
    [indicator stopAnimating];
    
    // iOS 13+ has UIBarButtonSystemItemClose, safe for iOS 14
    UIBarButtonItem *closeButton = [[UIBarButtonItem alloc]
                                    initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                                         target:self
                                                         action:@selector(actionClose)];
    self.navigationItem.rightBarButtonItem = closeButton;
    
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
            UIImage *img = [UIImage imageWithData:data];
            dispatch_async(dispatch_get_main_queue(), ^{
                cell.imageView.image = img ?: self.fallbackImage;
                [cell setNeedsLayout];
            });
        }
    }];
    [task resume];
}

@end
