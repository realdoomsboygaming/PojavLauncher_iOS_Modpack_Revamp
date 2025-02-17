#import "AFNetworking.h"
#import "LauncherNavigationController.h"
#import "ModpackInstallViewController.h"
#import "UIKit+AFNetworking.h"
#import "UIKit+hook.h"
#import "WFWorkflowProgressView.h"
#import "modpack/ModrinthAPI.h"
#import "config.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#include <dlfcn.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
#import <WebKit/WKDownload.h>
#pragma clang diagnostic pop

// Helper classes (placeholders)
@interface ImageCache : NSObject
+ (instancetype)shared;
- (UIImage *)imageForKey:(NSString *)key;
- (void)cacheImage:(UIImage *)image forKey:(NSString *)key;
@end

@interface ReachabilityManager : NSObject
+ (instancetype)shared;
- (BOOL)isReachable;
@end

#define kCurseForgeGameIDMinecraft 432
#define kCurseForgeClassIDModpack 4471
#define kCurseForgeClassIDMod 6

@interface ModpackInstallViewController()<UIContextMenuInteractionDelegate>
@property(nonatomic) UISearchController *searchController;
@property(nonatomic) UIMenu *currentMenu;
@property(nonatomic) NSMutableArray *list;
@property(nonatomic) NSMutableDictionary *filters;
@property(nonatomic) NSURLSessionDataTask *currentTask;
@property (nonatomic, strong) NSIndexPath *selectedIndexPath;
@property ModrinthAPI *modrinth;
@end

@implementation ModpackInstallViewController
@dynamic refreshControl;

- (void)viewDidLoad {
    [super viewDidLoad];

    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 80;
    
    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(handleRefresh:) 
                  forControlEvents:UIControlEventValueChanged];
    self.tableView.refreshControl = self.refreshControl;
    
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.navigationItem.searchController = self.searchController;
    
    self.modrinth = [ModrinthAPI new];
    self.filters = @{
        @"isModpack": @(YES),
        @"name": @" "
    }.mutableCopy;
    
    [self loadSearchResultsWithPrevList:NO];
}

- (void)handleRefresh:(UIRefreshControl *)sender {
    [self loadSearchResultsWithPrevList:NO];
    [sender endRefreshing];
}

- (void)loadSearchResultsWithPrevList:(BOOL)prevList {
    [self.currentTask cancel];
    
    if (![ReachabilityManager.shared isReachable]) {
        showDialog(localize(@"Error", nil), localize(@"No internet connection", nil));
        return;
    }
    
    NSString *name = self.searchController.searchBar.text;
    if (name.length < 3 && !prevList) {
        self.list = @[].mutableCopy;
        [self.tableView reloadData];
        return;
    }

    [self switchToLoadingState];
    __weak typeof(self) weakSelf = self;
    
    self.currentTask = [self.modrinth searchModWithFilters:self.filters 
                                       previousPageResult:prevList ? self.list : nil 
                                              completion:^(NSMutableArray *result, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                if (error.code != NSURLErrorCancelled) {
                    [weakSelf showError:error];
                }
                return;
            }
            
            weakSelf.list = result;
            [weakSelf.tableView reloadData];
            [weakSelf switchToReadyState];
        });
    }];
}

- (void)showError:(NSError *)error {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:localize(@"Error", nil)
        message:error.localizedDescription
        preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"Retry", nil)
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
        [self loadSearchResultsWithPrevList:NO];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil)
        style:UIAlertActionStyleCancel handler:nil]];
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateSearchResults) object:nil];
    [self performSelector:@selector(updateSearchResults) withObject:nil afterDelay:0.5];
}

- (void)updateSearchResults {
    [self loadSearchResultsWithPrevList:NO];
}

- (void)actionClose {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (void)switchToLoadingState {
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] 
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:indicator];
    [indicator startAnimating];
    self.navigationController.modalInPresentation = YES;
    self.tableView.allowsSelection = NO;
}

- (void)switchToReadyState {
    UIActivityIndicatorView *indicator = (id)self.navigationItem.rightBarButtonItem.customView;
    [indicator stopAnimating];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] 
        initWithBarButtonSystemItem:UIBarButtonSystemItemClose 
        target:self 
        action:@selector(actionClose)];
    self.navigationController.modalInPresentation = NO;
    self.tableView.allowsSelection = YES;
}

#pragma mark - UITableView

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.list.count + (self.modrinth.reachedLastPage ? 0 : 1);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= self.list.count) {
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"loading"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault 
                                          reuseIdentifier:@"loading"];
            UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] 
                initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
            [cell.contentView addSubview:spinner];
            spinner.translatesAutoresizingMaskIntoConstraints = NO;
            [NSLayoutConstraint activateConstraints:@[
                [spinner.centerXAnchor constraintEqualToAnchor:cell.contentView.centerXAnchor],
                [spinner.centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor]
            ]];
            [spinner startAnimating];
        }
        return cell;
    }
    
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
        cell.imageView.contentMode = UIViewContentModeScaleAspectFit;
        cell.imageView.clipsToBounds = YES;
        cell.imageView.layer.cornerRadius = 4;
        cell.imageView.layer.masksToBounds = YES;
        cell.textLabel.numberOfLines = 0;
        cell.detailTextLabel.numberOfLines = 0;
    }
    
    NSDictionary *item = self.list[indexPath.row];
    cell.textLabel.text = item[@"title"];
    cell.detailTextLabel.text = item[@"description"];
    cell.imageView.image = nil;
    
    // Image handling with cache
    UIImage *cachedImage = [ImageCache.shared imageForKey:item[@"imageUrl"]];
    if (cachedImage) {
        cell.imageView.image = cachedImage;
    } else {
        [cell.imageView setImageWithURLRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:item[@"imageUrl"]]
                             placeholderImage:[UIImage imageNamed:@"DefaultProfile"]
                                      success:^(NSURLRequest *request, NSHTTPURLResponse *response, UIImage *image) {
                                          [ImageCache.shared cacheImage:image forKey:item[@"imageUrl"]];
                                          cell.imageView.image = image;
                                      }
                                      failure:nil];
    }
    
    // Accessibility
    cell.isAccessibilityElement = YES;
    cell.accessibilityLabel = [NSString stringWithFormat:localize(@"Modpack: %@. Description: %@", nil),
                              item[@"title"], item[@"description"]];
    
    if (!self.modrinth.reachedLastPage && indexPath.row == self.list.count-1) {
        [self loadSearchResultsWithPrevList:YES];
    }

    return cell;
}

- (void)showDetails:(NSDictionary *)details atIndexPath:(NSIndexPath *)indexPath {
    self.selectedIndexPath = indexPath;
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
    
    NSMutableArray<UIAction *> *menuItems = [[NSMutableArray alloc] init];
    [details[@"versionNames"] enumerateObjectsUsingBlock:
    ^(NSString *name, NSUInteger i, BOOL *stop) {
        NSString *nameWithVersion = name;
        NSString *mcVersion = details[@"mcVersionNames"][i];
        if (![name hasSuffix:mcVersion]) {
            nameWithVersion = [NSString stringWithFormat:@"%@ - %@", name, mcVersion];
        }
        [menuItems addObject:[UIAction
            actionWithTitle:nameWithVersion
            image:nil identifier:nil
            handler:^(UIAction *action) {
            [self actionClose];
            NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
                [UIImagePNGRepresentation([cell.imageView.image _imageWithSize:CGSizeMake(40, 40)]) writeToFile:tmpIconPath atomically:YES];
            [self.modrinth installModpackFromDetail:self.list[indexPath.row] atIndex:i];
        }]];
    }];

    self.currentMenu = [UIMenu menuWithTitle:@"" children:menuItems];
    UIContextMenuInteraction *interaction = [[UIContextMenuInteraction alloc] initWithDelegate:self];
    cell.detailTextLabel.interactions = @[interaction];
    [interaction _presentMenuAtLocation:CGPointZero];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.row >= self.list.count) return;
    
    NSDictionary *item = self.list[indexPath.row];
    self.selectedIndexPath = indexPath;
    if ([item[@"versionDetailsLoaded"] boolValue]) {
        [self showDetails:item atIndexPath:indexPath];
        return;
    }
    
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    [self switchToLoadingState];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self.modrinth loadDetailsOfMod:self.list[indexPath.row]];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self switchToReadyState];
            if ([item[@"versionDetailsLoaded"] boolValue]) {
                [self showDetails:item atIndexPath:indexPath];
            } else {
                [self showError:self.modrinth.lastError];
            }
        });
    });
}

#pragma mark - Context Menu

- (UIContextMenuConfiguration *)contextMenuInteraction:(UIContextMenuInteraction *)interaction 
                         configurationForMenuAtLocation:(CGPoint)location {
    return [UIContextMenuConfiguration configurationWithIdentifier:nil 
        previewProvider:nil 
        actionProvider:^UIMenu * _Nullable(NSArray<UIMenuElement *> * _Nonnull suggestedActions) {
        return self.currentMenu;
    }];
}

- (void)tableView:(UITableView *)tableView 
        willPerformPreviewActionForMenuWithConfiguration:(UIContextMenuConfiguration *)configuration 
        animator:(id<UIContextMenuInteractionCommitAnimating>)animator {
    [animator addCompletion:^{
        if (self.selectedIndexPath) {
            [self tableView:tableView didSelectRowAtIndexPath:self.selectedIndexPath];
        }
    }];
}

@end
