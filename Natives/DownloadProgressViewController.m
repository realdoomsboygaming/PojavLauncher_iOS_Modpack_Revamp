#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import "DownloadProgressViewController.h"
#import "MinecraftResourceDownloadTask.h"

// Associated object keys.
static const void *kProgressKey = &kProgressKey;
static const void *kCellKey = &kCellKey;
static void *CellProgressObserverContext = &CellProgressObserverContext;
static void *TotalProgressObserverContext = &TotalProgressObserverContext;

@interface DownloadProgressViewController ()
@property (nonatomic, strong) NSTimer *refreshTimer;
@end

@implementation DownloadProgressViewController

// Initializer with task.
- (instancetype)initWithTask:(MinecraftResourceDownloadTask *)task {
    self = [super init];
    if (self) {
        self.task = task;
    }
    return self;
}

- (void)loadView {
    [super loadView];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
         initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(actionClose)];
    self.tableView.allowsSelection = NO;
}

// Use block-based NSTimer for clarity and to avoid potential retain cycles.
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.task.textProgress addObserver:self
                             forKeyPath:@"fractionCompleted"
                                options:(NSKeyValueObservingOptionNew | NSKeyValueObservingOptionInitial)
                                context:TotalProgressObserverContext];
    __weak typeof(self) weakSelf = self;
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer * _Nonnull timer) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf updateVisibleCells];
        }
    }];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    @try {
        [self.task.textProgress removeObserver:self forKeyPath:@"fractionCompleted"];
    } @catch (NSException *exception) {}
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

// Helper method to update a cell's UI based on its NSProgress.
- (void)updateCell:(UITableViewCell *)cell withProgress:(NSProgress *)progress {
    if (progress.finished) {
        cell.detailTextLabel.text = @"Done";
        cell.accessoryType = UITableViewCellAccessoryCheckmark;
    } else {
        double completed = progress.completedUnitCount;
        double total = progress.totalUnitCount;
        NSString *formatted = [NSString stringWithFormat:@"%.2f MB / %.2f MB", completed / 1048576.0, total / 1048576.0];
        cell.detailTextLabel.text = formatted;
        cell.accessoryType = UITableViewCellAccessoryNone;
    }
}

// Refreshes the visible cells in the table view.
- (void)updateVisibleCells {
    NSArray *visibleCells = [self.tableView visibleCells];
    BOOL allFinished = YES;
    for (UITableViewCell *cell in visibleCells) {
        NSProgress *progress = objc_getAssociatedObject(cell, kProgressKey);
        if (progress) {
            [self updateCell:cell withProgress:progress];
            if (!progress.finished) {
                allFinished = NO;
            }
        }
    }
    self.title = [NSString stringWithFormat:@"Downloading (%lu files)", (unsigned long)self.task.fileList.count];
    if (allFinished && self.task.fileList.count > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self actionClose];
        });
    }
}

// Closes the view controller.
- (void)actionClose {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context == CellProgressObserverContext) {
        NSProgress *progress = object;
        UITableViewCell *cell = objc_getAssociatedObject(progress, kCellKey);
        if (!cell) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateCell:cell withProgress:progress];
        });
    } else if (context == TotalProgressObserverContext) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.title = [NSString stringWithFormat:@"Downloading (%lu files)", (unsigned long)self.task.fileList.count];
        });
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

#pragma mark - UITableView DataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    @synchronized(self.task.fileList) {
        return self.task.fileList.count;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (!cell) {
       cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
       cell.accessoryType = UITableViewCellAccessoryNone;
    }
    
    NSString *fileName = @"";
    @synchronized(self.task.fileList) {
        if (indexPath.row < self.task.fileList.count) {
            fileName = self.task.fileList[indexPath.row];
        }
    }
    cell.textLabel.text = fileName;
    
    NSProgress *oldProgress = objc_getAssociatedObject(cell, kProgressKey);
    if (oldProgress) {
       @try {
           [oldProgress removeObserver:self forKeyPath:@"fractionCompleted"];
       } @catch (NSException *exception) {}
       objc_setAssociatedObject(cell, kProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    
    NSProgress *progress = nil;
    @synchronized(self.task.progressList) {
        if (indexPath.row < self.task.progressList.count) {
            progress = self.task.progressList[indexPath.row];
        }
    }
    if (!progress) {
       progress = [NSProgress progressWithTotalUnitCount:1];
       progress.completedUnitCount = 0;
    }
    
    objc_setAssociatedObject(cell, kProgressKey, progress, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(progress, kCellKey, cell, OBJC_ASSOCIATION_ASSIGN);
    [progress addObserver:self forKeyPath:@"fractionCompleted"
                options:(NSKeyValueObservingOptionNew | NSKeyValueObservingOptionInitial)
                context:CellProgressObserverContext];
    
    [self updateCell:cell withProgress:progress];
    
    return cell;
}

@end
