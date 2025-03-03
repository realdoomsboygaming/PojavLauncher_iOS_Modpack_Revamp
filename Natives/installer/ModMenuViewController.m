#import "ModMenuViewController.h"
#import "modpack/ModrinthAPI.h"
#import "modpack/CurseForgeAPI.h"
#import "config.h"
#import "UIKit+AFNetworking.h"
#import "utils.h"
#import "PLProfiles.h"

// Inline helper to display alerts.
static inline void presentAlertDialog(NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"OK", nil)
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    UIWindow *window = nil;
    if (@available(iOS 13.0, *)) {
         window = [UIApplication sharedApplication].windows.firstObject;
    } else {
         window = [UIApplication sharedApplication].keyWindow;
    }
    [window.rootViewController presentViewController:alert animated:YES completion:nil];
}

@interface ModMenuViewController ()
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) UISegmentedControl *apiSegmentedControl;
@property (nonatomic, strong) NSMutableArray *modsList;
@property (nonatomic, strong) ModrinthAPI *modrinth;
@property (nonatomic, strong) CurseForgeAPI *curseForge;
@property (nonatomic, strong) NSMutableDictionary *searchFilters;
// New properties for profile filtering.
@property (nonatomic, strong) NSString *selectedProfileName;
@property (nonatomic, strong) NSString *selectedMCVersion;
@end

@implementation ModMenuViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = @"Mods";
    self.modrinth = [ModrinthAPI new];
    self.curseForge = [[CurseForgeAPI alloc] initWithAPIKey:(CONFIG_CURSEFORGE_API_KEY ?: @"")];
    self.searchFilters = [@{@"isModpack": @(NO), @"name": @" "} mutableCopy];
    self.modsList = [NSMutableArray new];
    
    // Setup search controller.
    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.navigationItem.searchController = self.searchController;
    
    // Setup API segmented control.
    self.apiSegmentedControl = [[UISegmentedControl alloc] initWithItems:@[@"Modrinth", @"CurseForge"]];
    self.apiSegmentedControl.selectedSegmentIndex = 0;
    [self.apiSegmentedControl addTarget:self action:@selector(updateModsList) forControlEvents:UIControlEventValueChanged];
    self.tableView.tableHeaderView = self.apiSegmentedControl;
    
    // Add a left navigation bar button for profile selection.
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Profile"
                                                                             style:UIBarButtonItemStylePlain
                                                                            target:self
                                                                            action:@selector(actionChooseProfile)];
    
    [self updateModsList];
}

- (void)actionChooseProfile {
    // Get profiles from PLProfiles.
    NSDictionary *profiles = [PLProfiles current].profiles;
    if (!profiles || profiles.count == 0) {
        presentAlertDialog(localize(@"Error", nil), @"No profiles available.");
        return;
    }
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Select Profile"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    for (NSDictionary *profile in profiles.allValues) {
        NSString *name = profile[@"name"];
        [alert addAction:[UIAlertAction actionWithTitle:name
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            self.selectedProfileName = name;
            // Parse Minecraft version from lastVersionId.
            NSString *lastVersionId = profile[@"lastVersionId"];
            NSRange dashRange = [lastVersionId rangeOfString:@"-"];
            if (dashRange.location != NSNotFound) {
                self.selectedMCVersion = [lastVersionId substringToIndex:dashRange.location];
            } else {
                self.selectedMCVersion = lastVersionId;
            }
            // Update search filters.
            self.searchFilters[@"mcVersion"] = self.selectedMCVersion;
            [self updateModsList];
        }]];
    }
    
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil)
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    
    // For iPad compatibility.
    alert.popoverPresentationController.sourceView = self.view;
    alert.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width/2, self.view.bounds.size.height, 1, 1);
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)updateModsList {
    NSString *name = self.searchController.searchBar.text;
    self.searchFilters[@"name"] = name ?: @"";
    [self.modsList removeAllObjects];
    [self refreshModsListWithPrevList:NO];
}

- (void)refreshModsListWithPrevList:(BOOL)prevList {
    if (self.apiSegmentedControl.selectedSegmentIndex == 0) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSMutableArray *results = [self.modrinth searchModWithFilters:self.searchFilters previousPageResult:prevList ? self.modsList : nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (results) {
                    self.modsList = results;
                    [self.tableView reloadData];
                } else {
                    presentAlertDialog(localize(@"Error", nil), self.modrinth.lastError.localizedDescription);
                }
            });
        });
    } else {
        [self.curseForge searchModWithFilters:self.searchFilters previousPageResult:prevList ? self.modsList : nil completion:^(NSMutableArray *results, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (results) {
                    self.modsList = results;
                    [self.tableView reloadData];
                } else {
                    presentAlertDialog(localize(@"Error", nil), error.localizedDescription);
                }
            });
        }];
    }
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateModsList) object:nil];
    [self performSelector:@selector(updateModsList) withObject:nil afterDelay:0.5];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.modsList.count;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"modCell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"modCell"];
        cell.imageView.contentMode = UIViewContentModeScaleAspectFill;
        cell.imageView.clipsToBounds = YES;
    }
    NSDictionary *mod = self.modsList[indexPath.row];
    cell.textLabel.text = mod[@"title"];
    cell.detailTextLabel.text = mod[@"description"];
    UIImage *placeholder = [UIImage imageNamed:@"DefaultProfile"];
    [cell.imageView setImageWithURL:[NSURL URLWithString:mod[@"imageUrl"]] placeholderImage:placeholder];
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *mod = self.modsList[indexPath.row];
    if ([mod[@"versionDetailsLoaded"] boolValue]) {
        [self showModDetails:mod atIndexPath:indexPath];
    } else {
        [tableView deselectRowAtIndexPath:indexPath animated:NO];
        [self loadModDetailsForMod:mod atIndexPath:indexPath];
    }
}
- (void)loadModDetailsForMod:(NSDictionary *)mod atIndexPath:(NSIndexPath *)indexPath {
    __block NSMutableDictionary *modMutable = [mod mutableCopy];
    if (self.apiSegmentedControl.selectedSegmentIndex == 0) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self.modrinth loadDetailsOfMod:modMutable completion:^(NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if ([modMutable[@"versionDetailsLoaded"] boolValue]) {
                        [self.modsList replaceObjectAtIndex:indexPath.row withObject:modMutable];
                        [self showModDetails:modMutable atIndexPath:indexPath];
                    } else {
                        presentAlertDialog(localize(@"Error", nil), self.modrinth.lastError.localizedDescription);
                    }
                });
            }];
        });
    } else {
        [self.curseForge loadDetailsOfMod:modMutable completion:^(NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([modMutable[@"versionDetailsLoaded"] boolValue]) {
                    [self.modsList replaceObjectAtIndex:indexPath.row withObject:modMutable];
                    [self showModDetails:modMutable atIndexPath:indexPath];
                } else {
                    presentAlertDialog(localize(@"Error", nil), self.curseForge.lastError.localizedDescription);
                }
            });
        }];
    }
}

#pragma mark - Version Filtering and Dropdown

- (void)showModDetails:(NSDictionary *)mod atIndexPath:(NSIndexPath *)indexPath {
    NSArray *versionNames = mod[@"versionNames"];
    NSArray *mcVersionNames = mod[@"mcVersionNames"];
    
    NSLog(@"showModDetails: Loaded %lu versions", (unsigned long)versionNames.count);
    
    NSString *filterMC = self.selectedMCVersion;
    
    NSMutableArray<NSNumber *> *supportedIndices = [NSMutableArray array];
    NSMutableArray<NSString *> *supportedDisplayNames = [NSMutableArray array];
    for (NSUInteger i = 0; i < versionNames.count; i++) {
        NSString *version = versionNames[i];
        NSString *mcVersion = mcVersionNames[i];
        if (filterMC && filterMC.length > 0) {
            if ([version rangeOfString:filterMC].location != NSNotFound) {
                [supportedIndices addObject:@(i)];
                NSString *displayName = [version isEqualToString:mcVersion] ? version : [NSString stringWithFormat:@"%@ - %@", version, mcVersion];
                [supportedDisplayNames addObject:displayName];
            }
        } else {
            [supportedIndices addObject:@(i)];
            [supportedDisplayNames addObject:version];
        }
    }
    
    if (supportedIndices.count == 0) {
        NSLog(@"showModDetails: No supported versions found, falling back to all versions.");
        supportedIndices = [NSMutableArray array];
        supportedDisplayNames = [NSMutableArray array];
        for (NSUInteger i = 0; i < versionNames.count; i++) {
            [supportedIndices addObject:@(i)];
            [supportedDisplayNames addObject:versionNames[i]];
        }
    }
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Select Version" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSUInteger j = 0; j < supportedIndices.count; j++) {
        NSUInteger idx = [supportedIndices[j] unsignedIntegerValue];
        NSString *displayName = supportedDisplayNames[j];
        [alert addAction:[UIAlertAction actionWithTitle:displayName style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [self.modrinth installModFromDetail:mod atIndex:idx];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
