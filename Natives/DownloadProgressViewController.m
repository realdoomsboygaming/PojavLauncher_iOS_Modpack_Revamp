#import <dlfcn.h>
#import <objc/runtime.h>
#import "DownloadProgressViewController.h"

// Use static const pointers for associated object keys.
static const void *kProgressKey = &kProgressKey;
static const void *kCellKey = &kCellKey;
static void *CellProgressObserverContext = &CellProgressObserverContext;
static void *TotalProgressObserverContext = &TotalProgressObserverContext;

@interface DownloadProgressViewController ()
@property (nonatomic) NSInteger fileListCount;
@property (nonatomic, strong) NSTimer *refreshTimer;  // Periodic refresh timer
@end

@implementation DownloadProgressViewController

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

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    
    // Observe overall progress updates
    [self.task.textProgress addObserver:self
                             forKeyPath:@"fractionCompleted"
                                options:(NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew)
                                context:TotalProgressObserverContext];
    
    // Start timer to refresh table view every 0.5 seconds if observer doesn’t trigger
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                         target:self
                                                       selector:@selector(refreshTableView)
                                                       userInfo:nil
                                                        repeats:YES];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    
    @try {
        [self.task.textProgress removeObserver:self forKeyPath:@"fractionCompleted"];
    } @catch (NSException *exception) {}
    
    [self.refreshTimer invalidate];  // Stop the timer when the view disappears
    self.refreshTimer = nil;
}

// Ensures table refresh happens periodically even if KVO doesn’t trigger
- (void)refreshTableView {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.tableView reloadData];
    });
}

// Remove observers from cells when they go off-screen.
- (void)tableView:(UITableView *)tableView didEndDisplayingCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    NSProgress *progress = objc_getAssociatedObject(cell, kProgressKey);
    if (progress) {
        @try {
            [progress removeObserver:self forKeyPath:@"fractionCompleted"];
        } @catch (NSException *exception) {}
        objc_setAssociatedObject(cell, kProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

- (void)actionClose {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

// Observer for progress updates
- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context == CellProgressObserverContext) {
        NSProgress *progress = object;
        UITableViewCell *cell = objc_getAssociatedObject(progress, kCellKey);
        if (!cell) return;

        dispatch_async(dispatch_get_main_queue(), ^{
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0f%%", progress.fractionCompleted * 100];
            cell.accessoryType = progress.finished ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
            
            // Force update row without full reload
            NSIndexPath *indexPath = [self.tableView indexPathForCell:cell];
            if (indexPath) {
                [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
            }
        });
    } else if (context == TotalProgressObserverContext) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.title = [NSString stringWithFormat:@"Downloading: %.0f%%", self.task.textProgress.fractionCompleted * 100];
        });
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

#pragma mark - UITableView DataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.task.fileList.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (!cell) {
       cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
       cell.accessoryType = UITableViewCellAccessoryNone;
    }
    
    // Safely obtain the file name.
    NSString *fileName = @"";
    @synchronized(self.task.fileList) {
        if (indexPath.row < self.task.fileList.count) {
            fileName = self.task.fileList[indexPath.row];
        }
    }
    cell.textLabel.text = fileName;
    
    // Remove any previous observer associated with this cell.
    NSProgress *oldProgress = objc_getAssociatedObject(cell, kProgressKey);
    if (oldProgress) {
       @try {
           [oldProgress removeObserver:self forKeyPath:@"fractionCompleted"];
       } @catch (NSException *exception) {}
       objc_setAssociatedObject(cell, kProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    
    // Obtain NSProgress for this row in a thread-safe manner.
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
    
    // Associate progress with the cell.
    objc_setAssociatedObject(cell, kProgressKey, progress, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(progress, kCellKey, cell, OBJC_ASSOCIATION_ASSIGN);
    [progress addObserver:self forKeyPath:@"fractionCompleted"
                options:(NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew)
                context:CellProgressObserverContext];
    
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0f%%", progress.fractionCompleted * 100];
    cell.accessoryType = progress.finished ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    
    return cell;
}

@end
