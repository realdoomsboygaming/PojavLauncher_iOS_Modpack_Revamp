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
        [(CurseForgeAPI *)self.curseForge setParentViewController:self];
    } else {
        if (self.apiSegmentControl.selectedSegmentIndex == 0) {
            [self promptForCurseForgeAPIKey];
        }
    }
    
    self.modrinth = [ModrinthAPI new];
    self.filters = [@{@"isModpack": @(YES), @"name": @""} mutableCopy];
    self.fallbackImage = [UIImage imageNamed:@"DefaultProfile"];
    self.previousSearchText = @"";
    
    [self updateSearchResults];
}

- (void)promptForCurseForgeAPIKey {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"CurseForge API Key" message:@"Please enter your CurseForge API key" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"Your CF API Key here";
        textField.secureTextEntry = NO;
    }];
    
    __weak typeof(self) weakSelf = self;
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        NSString *key = alert.textFields.firstObject.text ?: @"";
        if (key.length > 0) {
            [[NSUserDefaults standardUserDefaults] setObject:key forKey:@"CURSEFORGE_API_KEY"];
            [[NSUserDefaults standardUserDefaults] synchronize];
            strongSelf.curseForge = [[CurseForgeAPI alloc] initWithAPIKey:key];
            [(CurseForgeAPI *)strongSelf.curseForge setParentViewController:strongSelf];
            [strongSelf updateSearchResults];
        } else {
            strongSelf.apiSegmentControl.selectedSegmentIndex = 1;
            [strongSelf updateSearchResults];
        }
    }];
    [alert addAction:okAction];
    
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction * _Nonnull action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        strongSelf.apiSegmentControl.selectedSegmentIndex = 1;
        [strongSelf updateSearchResults];
    }];
    [alert addAction:cancelAction];
    
    [self presentViewController:alert animated:YES completion:nil];
}

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

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateSearchResults) object:nil];
    [self performSelector:@selector(updateSearchResults) withObject:nil afterDelay:0.5];
}

- (void)updateSearchResults {
    [self loadSearchResultsWithPrevList:NO];
}

- (void)loadSearchResultsWithPrevList:(BOOL)prevList {
    NSString *currentSearchText = self.searchController.searchBar.text ?: @"";
    if (!prevList && [self.previousSearchText isEqualToString:currentSearchText]) {
        return;
    }
    self.previousSearchText = currentSearchText;
    self.filters[@"name"] = currentSearchText;
    
    [self switchToLoadingState];
    
    if (self.apiSegmentControl.selectedSegmentIndex == 0) {
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
        [(CurseForgeAPI *)self.curseForge searchModWithFilters:self.filters previousPageResult:(prevList ? self.list : nil) completion:^(NSMutableArray * _Nullable results, NSError * _Nullable error) {
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
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSMutableArray *results = [self.modrinth searchModWithFilters:self.filters previousPageResult:(prevList ? self.list : nil)];
            NSError *searchError = [self.modrinth lastError];
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
    BOOL reachedLastPage = usingCurseForge ? [(CurseForgeAPI *)self.curseForge reachedLastPage] : [self.modrinth reachedLastPage];
    if (!reachedLastPage && indexPath.row == self.list.count - 1) {
        [self loadSearchResultsWithPrevList:YES];
    }
    
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSMutableDictionary *item = self.list[indexPath.row];
    
    if (![item[@"versionDetailsLoaded"] boolValue]) {
        __weak typeof(self) weakSelf = self;
        if (self.apiSegmentControl.selectedSegmentIndex == 0) {
            [(CurseForgeAPI *)self.curseForge loadDetailsOfMod:item completion:^(NSError * _Nullable error) {
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
            // Show loading indicator for modrinth to prevent UI freeze
            UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
            UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
            indicator.center = cell.contentView.center;
            [indicator startAnimating];
            [cell.contentView addSubview:indicator];
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                [self.modrinth loadDetailsOfMod:item];
                item[@"versionDetailsLoaded"] = @(YES);
                dispatch_async(dispatch_get_main_queue(), ^{
                    [indicator removeFromSuperview];
                    [self showDetails:item atIndexPath:indexPath];
                });
            });
        }
    } else {
        [self showDetails:item atIndexPath:indexPath];
    }
}

- (void)showDetails:(NSDictionary *)details atIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Select Version" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    
    NSArray *versionNames = details[@"versionNames"];
    NSArray *mcVersionNames = details[@"mcVersionNames"];
    if (![versionNames isKindOfClass:[NSArray class]] || ![mcVersionNames isKindOfClass:[NSArray class]]) {
        return;
    }
    
    [versionNames enumerateObjectsUsingBlock:^(NSString *name, NSUInteger i, BOOL *stop) {
        NSString *mcVersion = (i < mcVersionNames.count ? mcVersionNames[i] : @"");
        NSString *fullText = ([name rangeOfString:mcVersion].location != NSNotFound ? name : [NSString stringWithFormat:@"%@ - %@", name, mcVersion]);
        UIAlertAction *versionAction = [UIAlertAction actionWithTitle:fullText style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
            NSData *imgData = UIImagePNGRepresentation(cell.imageView.image);
            [imgData writeToFile:tmpIconPath atomically:YES];
            
            if (self.apiSegmentControl.selectedSegmentIndex == 0) {
                [(CurseForgeAPI *)self.curseForge installModpackFromDetail:self.list[indexPath.row] atIndex:i completion:^(NSError * _Nullable error) {
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
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    
    if (alert.popoverPresentationController) {
        alert.popoverPresentationController.sourceView = cell;
        alert.popoverPresentationController.sourceRect = cell.bounds;
        alert.popoverPresentationController.permittedArrowDirections = UIPopoverArrowDirectionAny;
    }
    
    [self presentViewController:alert animated:YES completion:nil];
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
    UIBarButtonItem *closeButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(actionClose)];
    self.navigationItem.rightBarButtonItem = closeButton;
    self.navigationController.modalInPresentation = NO;
    self.tableView.allowsSelection = YES;
}

- (void)actionClose {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

@end

NS_ASSUME_NONNULL_END

NS_ASSUME_NONNULL_END
