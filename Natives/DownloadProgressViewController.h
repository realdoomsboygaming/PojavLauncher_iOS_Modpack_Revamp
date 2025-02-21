#import <UIKit/UIKit.h>
#import "MinecraftResourceDownloadTask.h"

@interface DownloadProgressViewController : UITableViewController
@property (nonatomic, strong) MinecraftResourceDownloadTask *task;
- (instancetype)initWithTask:(MinecraftResourceDownloadTask *)task;
@end
