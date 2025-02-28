#import "ModpackInstallViewController.h"
#import "LauncherNavigationController.h"
#import "WFWorkflowProgressView.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import "config.h"
#import "modpack/CurseForgeAPI.h"
#import "modpack/ModrinthAPI.h"

NS_ASSUME_NONNULL_BEGIN

@interface ModpackInstallViewController () <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UIImage *fallbackImage;
@property (nonatomic, strong) UIMenu *currentMenu;
@property (nonatomic, copy) NSString *previousSearchText;
@end

@implementation ModpackInstallViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.definesPresentationContext = YES;
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    
    // Setup search controller.
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.navigationItem.searchController = self.searchController;
    
    // Setup API selection segmented control.
    self.apiSegmentControl = [[UISegmentedControl alloc] initWithItems:@[@"CurseForge", @"Modrinth"]];
    self.apiSegmentControl.selectedSegmentIndex = 0;
    self.apiSegmentControl.frame = CGRectMake(0, 0, 200, 30);
    [self.apiSegmentControl addTarget:self action:@selector(apiSegmentChanged:) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = self.apiSegmentControl;
    
    // Initialize CurseForgeAPI if API key exists; otherwise prompt user.
    NSString *storedKey = [[NSUserDefaults standardUserDefaults] stringForKey:@"CURSEFORGE_API_KEY"];
    if (storedKey.length > 0) {
        self.curseForge = [[CurseForgeAPI alloc] initWithAPIKey:storedKey];
        self.curseForge.parentViewController = self;
    } else {
        if (self.apiSegmentControl.selectedSegmentIndex == 0) {
            [self promptForCurseForgeAPIKey];
        }
    }
    
    self.modrinth = [ModrinthAPI new];
    self.filters = [@{@"isModpack": @(YES), @"name": @""} mutableCopy];
    self.fallbackImage = [UIImage imageNamed:@"DefaultProfile"];
    self.previousSearchText = @""; // Ensure first search runs.
    
    [self updateSearchResults];
}

#pragma mark - API Key Prompt

- (void)promptForCurseForgeAPIKey {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"CurseForge API Key"
                                                                   message:@"Please enter your CurseForge API key"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"Your CF API Key here";
        textField.secureTextEntry = NO;
    }];
    
    __weak typeof(self) weakSelf = self;
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"OK"
                                                       style:UIAlertActionStyleDefault
                                                     handler:^(UIAlertAction * _Nonnull action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        NSString *key = alert.textFields.firstObject.text ?: @"";
        if (key.length > 0) {
            [[NSUserDefaults standardUserDefaults] setObject:key forKey:@"CURSEFORGE_API_KEY"];
            [[NSUserDefaults standardUserDefaults] synchronize];
            strongSelf.curseForge = [[CurseForgeAPI alloc] initWithAPIKey:key];
            strongSelf.curseForge.parentViewController = strongSelf;
            [strongSelf updateSearchResults];
        } else {
            strongSelf.apiSegmentControl.selectedSegmentIndex = 1;
            [strongSelf updateSearchResults];
        }
    }];
    [alert addAction:okAction];
    
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel"
                                                           style:UIAlertActionStyleCancel
                                                         handler:^(UIAlertAction * _Nonnull action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        strongSelf.apiSegmentControl.selectedSegmentIndex = 1;
        [strongSelf updateSearchResults];
    }];
    [alert addAction:cancelAction];
    
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - UISegmentedControl Action

- (void)apiSegmentChanged:(UISegmentedControl *)sender {
    if (sender.selectedSegmentIndex == 0) {
        NSString *key = [[NSUserDefaults standardUserDefaults] stringForKey:@"CURSEFORGE_API_KEY"];
        if (!key || key.length == 0) {
            [self promptForCurseForgeAPIKey];
            return;
        }
    }
    [self.list removeAllObjects];
    [self.tableView reloadData];
    [self updateSearchResults];
}

#pragma mark - UISearchResultsUpdating

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateSearchResults) object:nil];
    [self performSelector:@selector(updateSearchResults) withObject:nil afterDelay:0.5];
}

- (void)updateSearchResults {
    [self loadSearchResultsWithPrevList:NO];
}

#pragma mark - Loading Search Results

- (void)loadSearchResultsWithPrevList:(BOOL)prevList {
    NSString *currentSearchText = self.searchController.searchBar.text ?: @"";
    if (!prevList && [self.previousSearchText isEqualToString:currentSearchText]) {
        return;
    }
    self.previousSearchText = currentSearchText;
    self.filters[@"name"] = currentSearchText;
    
    [self switchToLoadingState];
    
    if (self.apiSegmentControl.selectedSegmentIndex == 0) {
        // CurseForge search.
        if (!self.curseForge) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self switchToReadyState];
                showDialog(@"Missing CF Key", @"No CurseForge API key provided. Switching to Modrinth.");
                self.apiSegmentControl.selectedSegmentIndex = 1;
                [self updateSearchResults];
            });
            return;
        }
        __weak typeof(self) weakSelf = self;
        [self.curseForge searchModWithFilters:self.filters previousPageResult:(prevList ? self.list : nil)
                                   completion:^(NSMutableArray * _Nullable results, NSError * _Nullable error)
        {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (results) {
                    strongSelf.list = results;
                    [strongSelf.tableView reloadData];
                } else if (error) {
                    showDialog(localize(@"Error", nil), error.localizedDescription);
                }
                [strongSelf switchToReadyState];
            });
        }];
    } else {
        // Modrinth search on background thread.
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSMutableArray *results = [weakSelf.modrinth searchModWithFilters:weakSelf.filters previousPageResult:(prevList ? weakSelf.list : nil)];
            NSError *searchError = weakSelf.modrinth.lastError;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (results) {
                    strongSelf.list = results;
                    [strongSelf.tableView reloadData];
                } else if (searchError) {
                    showDialog(localize(@"Error", nil), searchError.localizedDescription);
                }
                [strongSelf switchToReadyState];
            });
        });
    }
}

#pragma mark - TableView DataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.list.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
        cell.imageView.contentMode = UIViewContentModeScaleAspectFit;
        cell.imageView.clipsToBounds = YES;
        // Add context menu interaction (iOS 13+).
        UIContextMenuInteraction *interaction = [[UIContextMenuInteraction alloc] initWithDelegate:self];
        [cell addInteraction:interaction];
    }
    
    NSDictionary *item = self.list[indexPath.row];
    cell.textLabel.text = ([item[@"title"] isKindOfClass:[NSString class]] ? item[@"title"] : @"Untitled");
    cell.detailTextLabel.text = ([item[@"description"] isKindOfClass:[NSString class]] ? item[@"description"] : @"No description");
    
    NSString *imageUrl = ([item[@"imageUrl"] isKindOfClass:[NSString class]] ? item[@"imageUrl"] : @"");
    if (imageUrl.length > 0) {
        [self loadImageForCell:cell withURL:imageUrl];
    } else {
        cell.imageView.image = self.fallbackImage;
    }
    
    BOOL usingCurseForge = (self.apiSegmentControl.selectedSegmentIndex == 0);
    BOOL reachedLastPage = usingCurseForge ? self.curseForge.reachedLastPage : self.modrinth.reachedLastPage;
    if (!reachedLastPage && indexPath.row == self.list.count - 1) {
        [self loadSearchResultsWithPrevList:YES];
    }
    
    return cell;
}

#pragma mark - TableView Delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSMutableDictionary *item = self.list[indexPath.row];
    
    if (![item[@"versionDetailsLoaded"] boolValue]) {
        __weak typeof(self) weakSelf = self;
        if (self.apiSegmentControl.selectedSegmentIndex == 0) {
            [self.curseForge loadDetailsOfMod:item completion:^(NSError * _Nullable error) {
                __strong typeof(weakSelf) strongSelf = weakSelf;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (error) {
                        showDialog(localize(@"Error", nil), error.localizedDescription);
                    } else {
                        item[@"versionDetailsLoaded"] = @(YES);
                        [strongSelf showDetails:item atIndexPath:indexPath];
                    }
                });
            }];
        } else {
            __weak typeof(self) weakSelfMod = self;
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                [weakSelfMod.modrinth loadDetailsOfMod:item];
                item[@"versionDetailsLoaded"] = @(YES);
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelfMod) strongSelf = weakSelfMod;
                    [strongSelf showDetails:item atIndexPath:indexPath];
                });
            });
        }
    } else {
        [self showDetails:item atIndexPath:indexPath];
    }
}

#pragma mark - Context Menu (iOS 13+)

- (UIContextMenuConfiguration * _Nullable)tableView:(UITableView *)tableView
contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
                                           point:(CGPoint)point {
    return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                     previewProvider:nil
                                                      actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
        return self.currentMenu;
    }];
}

- (UIContextMenuConfiguration * _Nullable)contextMenuInteraction:(UIContextMenuInteraction *)interaction
                 configurationForMenuAtLocation:(CGPoint)location {
    return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                     previewProvider:nil
                                                      actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
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
    if (![versionNames isKindOfClass:[NSArray class]] || ![mcVersionNames isKindOfClass:[NSArray class]]) {
        return;
    }
    
    [versionNames enumerateObjectsUsingBlock:^(NSString *name, NSUInteger i, BOOL *stop) {
        NSString *mcVersion = (i < mcVersionNames.count ? mcVersionNames[i] : @"");
        NSString *fullText = ([name rangeOfString:mcVersion].location != NSNotFound
                              ? name
                              : [NSString stringWithFormat:@"%@ - %@", name, mcVersion]);
        UIAlertAction *versionAction = [UIAlertAction actionWithTitle:fullText
                                                                style:UIAlertActionStyleDefault
                                                              handler:^(UIAlertAction * _Nonnull action)
        {
            // Save cell image temporarily.
            NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
            NSData *imgData = UIImagePNGRepresentation(cell.imageView.image);
            [imgData writeToFile:tmpIconPath atomically:YES];
            
            if (self.apiSegmentControl.selectedSegmentIndex == 0) {
                __weak typeof(self) weakSelf = self;
                [self.curseForge installModpackFromDetail:self.list[indexPath.row] atIndex:i completion:^(NSError * _Nullable error) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (error) {
                            showDialog(localize(@"Error", nil), error.localizedDescription);
                        } else {
                            [weakSelf actionClose];
                        }
                    });
                }];
            } else {
                [self.modrinth installModpackFromDetail:self.list[indexPath.row] atIndex:i];
                [self actionClose];
            }
        }];
        [alert addAction:versionAction];
    }];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    
    if (alert.popoverPresentationController) {
        alert.popoverPresentationController.sourceView = cell;
        alert.popoverPresentationController.sourceRect = cell.bounds;
        alert.popoverPresentationController.permittedArrowDirections = UIPopoverArrowDirectionAny;
    }
    
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - UI State Management

- (void)switchToLoadingState {
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc]
                                            initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [indicator startAnimating];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:indicator];
    
    self.navigationController.modalInPresentation = YES;
    self.tableView.allowsSelection = NO;
}

- (void)switchToReadyState {
    UIActivityIndicatorView *indicator = (id)self.navigationItem.rightBarButtonItem.customView;
    [indicator stopAnimating];
    
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
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url
                                                             completionHandler:^(NSData *data, NSURLResponse *response, NSError *error)
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

NS_ASSUME_NONNULL_END
