#import <UIKit/UIKit.h>
#import "modpack/ModrinthAPI.h"
#import "modpack/CurseForgeAPI.h"

NS_ASSUME_NONNULL_BEGIN

@interface ModpackInstallViewController : UITableViewController <UISearchResultsUpdating, UIContextMenuInteractionDelegate>

@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) UISegmentedControl *apiSegmentControl;
@property (nonatomic, strong) NSMutableArray *list;
@property (nonatomic, strong) NSMutableDictionary *filters;
@property (nonatomic, strong) ModrinthAPI *modrinth;
@property (nonatomic, strong) CurseForgeAPI *curseForge;

- (void)updateSearchResults;

@end

NS_ASSUME_NONNULL_END
