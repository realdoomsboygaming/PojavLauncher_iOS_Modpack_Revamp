#import <UIKit/UIKit.h>
#import "PLPrefTableViewController.h"

@interface FabricInstallViewController : PLPrefTableViewController
@property (nonatomic, strong) NSString *modpackDirectory; // Path to modpack directory for modloader installer info
@end
