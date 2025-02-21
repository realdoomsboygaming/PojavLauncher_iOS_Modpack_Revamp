#import "ModpackInstallViewController.h"
#import "LauncherNavigationController.h"
#import "WFWorkflowProgressView.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import "config.h"
#import "modpack/CurseForgeAPI.h"
#import "modpack/ModrinthAPI.h"

NS_ASSUME_NONNULL_BEGIN

@interface ModpackInstallViewController () <UITableViewDelegate, UITableViewDataSource, UIContextMenuInteractionDelegate>
@property (nonatomic, strong) UIImage *fallbackImage;
@property (nonatomic, strong) UIMenu *currentMenu;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIImage *> *previewImages;
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
    self.filters = [[NSMutableDictionary alloc] initWithObjectsAndKeys:@(YES), @"isModpack", @"", @"name"];
    self.fallbackImage = [UIImage imageNamed:@"DefaultProfile"];
    self.previewImages = [[NSMutableDictionary alloc] init];
    self.previousSearchText = @""; // so the first search always runs
    
    [self updateSearchResults];
}

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
                               completion:^(NSMutableArray * _Nullable results, NSError * _Nullable error) {
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

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView 
         contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath 
                                    point:(CGPoint)point {
    NSDictionary *item = self.list[indexPath.row];
    
    return [UIContextMenuConfiguration configurationWithIdentifier:item[@"id"]
                                                     previewProvider:^UIViewController * _Nullable(UILargeTitleDisplayMode largeTitleDisplayMode) {
        UIViewController *previewVC = [[UIViewController alloc] init];
        previewVC.view.backgroundColor = [UIColor whiteColor];
        
        UIImageView *imageView = [[UIImageView alloc] initWithFrame:CGRectZero];
        imageView.contentMode = UIViewContentModeScaleAspectFit;
        NSString *imageUrl = item[@"imageUrl"];
        
        if (imageUrl.length > 0) {
            UIImage *cachedImage = self.previewImages[imageUrl];
            if (!cachedImage) {
                cachedImage = self.fallbackImage;
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    NSURL *url = [NSURL URLWithString:imageUrl];
                    NSData *data = [NSData dataWithContentsOfURL:url];
                    if (data) {
                        UIImage *img = [UIImage imageWithData:data];
                        if (img) {
                            [self.previewImages setObject:img forKey:imageUrl];
                        }
                    }
                });
            }
            imageView.image = cachedImage;
        } else {
            imageView.image = self.fallbackImage;
        }
        
        UILabel *titleLabel = [[UILabel alloc] init];
        titleLabel.text = item[@"title"];
        titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleLargeTitle];
        
        UILabel *descriptionLabel = [[UILabel alloc] init];
        descriptionLabel.text = item[@"description"];
        descriptionLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
        descriptionLabel.numberOfLines = 0;
        
        [previewVC.view addSubview:imageView];
        [previewVC.view addSubview:titleLabel];
        [previewVC.view addSubview:descriptionLabel];
        
        imageView.translatesAutoresizingMaskIntoConstraints = NO;
        titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = NO;
        
        [NSLayoutConstraint activate:@[
            [imageView.topAnchor constraintEqualToAnchor:previewVC.view.safeAreaLayoutGuide.topAnchor constant:16],
            [imageView.leadingAnchor constraintEqualToAnchor:previewVC.view.safeAreaLayoutGuide.leadingAnchor constant:16],
            [imageView.trailingAnchor constraintEqualToAnchor:previewVC.view.safeAreaLayoutGuide.trailingAnchor constant:-16],
            [imageView.heightAnchor constraintEqualToConstant:200],
            
            [titleLabel.topAnchor constraintEqualToAnchor:imageView.bottomAnchor constant:16],
            [titleLabel.leadingAnchor constraintEqualToAnchor:previewVC.view.safeAreaLayoutGuide.leadingAnchor constant:16],
            [titleLabel.trailingAnchor constraintEqualToAnchor:previewVC.view.safeAreaLayoutGuide.trailingAnchor constant:-16],
            
            [descriptionLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:8],
            [descriptionLabel.leadingAnchor constraintEqualToAnchor:previewVC.view.safeAreaLayoutGuide.leadingAnchor constant:16],
            [descriptionLabel.trailingAnchor constraintEqualToAnchor:previewVC.view.safeAreaLayoutGuide.trailingAnchor constant:-16]
        ]];
        
        return previewVC;
    } handler:^UIMenu * _Nullable(NSArray<UIMenuElement *> *suggestedActions) {
        UIAction *installAction = [UIAction actionWithTitle:@"Install"
                                                    image:[UIImage systemImageNamed:@"download"]
                                                  identifier:nil
                                                  handler:^(UIAction *action) {
            [self tableView:tableView didSelectRowAtIndexPath:indexPath];
        }];
        
        UIAction *shareAction = [UIAction actionWithTitle:@"Share"
                                                 image:[UIImage systemImageNamed:@"square.and.arrow.up"]
                                               identifier:nil
                                               handler:^(UIAction *action) {
            // Implement sharing logic
        }];
        
        UIAction *detailsAction = [UIAction actionWithTitle:@"Show Details"
                                                   image:[UIImage systemImageNamed:@"info"]
                                                 identifier:nil
                                                 handler:^(UIAction *action) {
            [self tableView:tableView didSelectRowAtIndexPath:indexPath];
        }];
        
        return [UIMenu menuWithTitle:@"" children:@[installAction, shareAction, detailsAction]];
    }];
}

- (UITargetedPreview *)tableView:(UITableView *)tableView 
       previewForHighlightingContextMenuWithConfiguration:(UIContextMenuConfiguration *)configuration {
    NSIndexPath *indexPath = [tableView indexPathForIdentifier:configuration.identifier];
    if (!indexPath) return nil;
    
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    if (!cell) return nil;
    
    UITargetedPreview *preview = [[UITargetedPreview alloc] initWithView:cell
        parameters:[UIPreviewParameters new]];
    preview.targetRect = cell.frame;
    return preview;
}

- (UITargetedPreview *)tableView:(UITableView *)tableView 
       previewForDismissingContextMenuWithConfiguration:(UIContextMenuConfiguration *)configuration {
    NSIndexPath *indexPath = [tableView indexPathForIdentifier:configuration.identifier];
    if (!indexPath) return nil;
    
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    if (!cell) return nil;
    
    UITargetedPreview *preview = [[UITargetedPreview alloc] initWithView:cell
        parameters:[UIPreviewParameters new]];
    preview.targetRect = cell.frame;
    return preview;
}

- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction 
         configurationForMenuAtLocation:(CGPoint)location {
    return [UIContextMenuConfiguration configurationWithIdentifier:nil
                                                     previewProvider:nil
                                                      actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
        return self.currentMenu;
    }];
}

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
                                                              handler:^(UIAlertAction * _Nonnull action) {
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

- (void)loadImageForCell:(UITableViewCell *)cell withURL:(NSString *)urlString {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return;
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url
                                                             completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
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
