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
// Prevent repeated searches when the text hasn't changed
@property (nonatomic, copy) NSString *previousSearchText;
@end

@implementation ModpackInstallViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.definesPresentationContext = YES;
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.navigationItem.searchController = self.searchController;
    
    self.apiSegmentControl = [[UISegmentedControl alloc] initWithItems:@[@"CurseForge", @"Modrinth"]];
    self.apiSegmentControl.selectedSegmentIndex = 0;
    self.apiSegmentControl.frame = CGRectMake(0, 0, 200, 30);
    [self.apiSegmentControl addTarget:self action:@selector(apiSegmentChanged:) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = self.apiSegmentControl;
    
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
    self.previousSearchText = @""; // so the first search always runs
    
    [self updateSearchResults];
}

#pragma mark - Prompt for CF Key if Missing

- (void)promptForCurseForgeAPIKey {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"CurseForge API Key"
                                                                   message:@"Please enter your CurseForge API key"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"Your CF API Key here";
        textField.secureTextEntry = NO;
    }];
    
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"OK"
                                                       style:UIAlertActionStyleDefault
                                                     handler:^(UIAlertAction * _Nonnull action) {
        NSString *key = alert.textFields.firstObject.text ?: @"";
        if (key.length > 0) {
            [[NSUserDefaults standardUserDefaults] setObject:key forKey:@"CURSEFORGE_API_KEY"];
            [[NSUserDefaults standardUserDefaults] synchronize];
            self.curseForge = [[CurseForgeAPI alloc] initWithAPIKey:key];
            self.curseForge.parentViewController = self;
            [self updateSearchResults];
        } else {
            self.apiSegmentControl.selectedSegmentIndex = 1;
            [self updateSearchResults];
        }
    }];
    [alert addAction:okAction];
    
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel"
                                                           style:UIAlertActionStyleCancel
                                                         handler:^(UIAlertAction * _Nonnull action) {
        self.apiSegmentControl.selectedSegmentIndex = 1;
        [self updateSearchResults];
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
        return; // no need to search again
    }
    self.previousSearchText = currentSearchText;
    self.filters[@"name"] = currentSearchText;
    
    [self switchToLoadingState];
    
    if (self.apiSegmentControl.selectedSegmentIndex == 0) {
        // CurseForge
        if (!self.curseForge) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self switchToReadyState];
                showDialog(@"Missing CF Key", @"No CurseForge API key provided. Switching to Modrinth.");
                self.apiSegmentControl.selectedSegmentIndex = 1;
                [self updateSearchResults];
            });
            return;
        }
        [self.curseForge searchModWithFilters:self.filters previousPageResult:(prevList ? self.list : nil)
                                   completion:^(NSMutableArray * _Nullable results, NSError * _Nullable error)
        {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (results) {
                    self.list = results;
                    [self.tableView reloadData];
                } else if (error) {
                    showDialog(localize(@"Error", nil), error.localizedDescription);
                }
                [self switchToReadyState];
            });
        }];
    } else {
        // Modrinth
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSMutableArray *results = [self.modrinth searchModWithFilters:self.filters
                                                     previousPageResult:(prevList ? self.list : nil)];
            NSError *searchError = self.modrinth.lastError;
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
        // Trigger next page
        [self loadSearchResultsWithPrevList:YES];
    }
    
    return cell;
}

#pragma mark - TableView Delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSMutableDictionary *item = self.list[indexPath.row];
    
    if (![item[@"versionDetailsLoaded"] boolValue]) {
        if (self.apiSegmentControl.selectedSegmentIndex == 0) {
            [self.curseForge loadDetailsOfMod:item completion:^(NSError * _Nullable error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (error) {
                        showDialog(localize(@"Error", nil), error.localizedDescription);
                    } else {
                        item[@"versionDetailsLoaded"] = @(YES);
                        [self showDetails:item atIndexPath:indexPath];
                    }
                });
            }];
        } else {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                [self.modrinth loadDetailsOfMod:item];
                item[@"versionDetailsLoaded"] = @(YES);
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self showDetails:item atIndexPath:indexPath];
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
    if (![versionNames isKindOfClass:[NSArray class]] ||
        ![mcVersionNames isKindOfClass:[NSArray class]]) {
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
            NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
            NSData *imgData = UIImagePNGRepresentation(cell.imageView.image);
            [imgData writeToFile:tmpIconPath atomically:YES];
            
            if (self.apiSegmentControl.selectedSegmentIndex == 0) {
                [self.curseForge installModpackFromDetail:self.list[indexPath.row] atIndex:i completion:^(NSError * _Nullable error) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (error) {
                            showDialog(localize(@"Error", nil), error.localizedDescription);
                        } else {
                            [self actionClose];
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
