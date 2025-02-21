#import <UIKit/UIKit.h>

@interface FileListViewController : UITableViewController

@property (nonatomic, strong) NSString *listPath;
@property (nonatomic, copy) void (^whenDelete)(NSString *name);
@property (nonatomic, copy) void (^whenItemSelected)(NSString *name);

@end
