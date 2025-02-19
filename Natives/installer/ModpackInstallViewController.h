#import <UIKit/UIKit.h>
#import "modpack/ModrinthAPI.h"
#import "modpack/CurseForgeAPI.h"

@interface ModpackInstallViewController : UIViewController <UIContextMenuInteractionDelegate, UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISearchController *searchController;
@property (nonatomic, strong) UIMenu *currentMenu;
@property (nonatomic, strong) NSMutableArray *list;
@property (nonatomic, strong) NSMutableDictionary *filters;
@property (nonatomic, strong) ModrinthAPI *modrinth;
@property (nonatomic, strong) CurseForgeAPI *curseForge;
@property (nonatomic, strong) UISegmentedControl *apiSegmentControl;

@end
