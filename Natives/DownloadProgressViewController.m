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
@property (nonatomic, strong) NSTimer *refreshTimer;
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
    // We rely on updating each cell's labels via our timer and KVO without reloading the table entirely.
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // Observe overall progress changes.
    [self.task.textProgress addObserver:self
                             forKeyPath:@"fractionCompleted"
                                options:(NSKeyValueObservingOptionNew | NSKeyValueObservingOptionInitial)
                                context:TotalProgressObserverContext];
    // Start a timer to update visible cells every 0.5 seconds.
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                         target:self
                                                       selector:@selector(updateVisibleCells)
                                                       userInfo:nil
                                                        repeats:YES];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    @try {
        [self.task.textProgress removeObserver:self forKeyPath:@"fractionCompleted"];
    } @catch (NSException *exception) {}
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

- (void)updateVisibleCells {
    // Update only the visible cells to avoid reloading the entire table.
    NSArray *visibleIndexPaths = [self.tableView indexPathsForVisibleRows];
    if (!visibleIndexPaths) { return; }
    for (NSIndexPath *indexPath in visibleIndexPaths) {
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
        NSProgress *progress = objc_getAssociatedObject(cell, kProgressKey);
        if (progress) {
            // Instead of percentage, show "Done" if finished; otherwise, leave detail empty.
            cell.detailTextLabel.text = progress.finished ? @"Done" : @"";
            cell.accessoryType = progress.finished ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        }
    }
    // Also update overall title.
    dispatch_async(dispatch_get_main_queue(), ^{
        self.title = [NSString stringWithFormat:@"Downloading (%lu files)", (unsigned long)self.task.fileList.count];
    });
}

- (void)actionClose {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

// KVO observer for individual cell progress updates.
- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context == CellProgressObserverContext) {
        NSProgress *progress = object;
        UITableViewCell *cell = objc_getAssociatedObject(progress, kCellKey);
        if (!cell) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            cell.detailTextLabel.text = progress.finished ? @"Done" : @"";
            cell.accessoryType = progress.finished ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        });
    } else if (context == TotalProgressObserverContext) {
        // Update the overall title.
        dispatch_async(dispatch_get_main_queue(), ^{
            self.title = [NSString stringWithFormat:@"Downloading (%lu files)", (unsigned long)self.task.fileList.count];
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
    // Dequeue a reusable cell.
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (!cell) {
       cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"cell"];
       cell.accessoryType = UITableViewCellAccessoryNone;
    }
    
    // Obtain file name safely.
    NSString *fileName = @"";
    @synchronized(self.task.fileList) {
        if (indexPath.row < self.task.fileList.count) {
            fileName = self.task.fileList[indexPath.row];
        }
    }
    cell.textLabel.text = fileName;
    
    // Remove any previous observer and association.
    NSProgress *oldProgress = objc_getAssociatedObject(cell, kProgressKey);
    if (oldProgress) {
       @try {
           [oldProgress removeObserver:self forKeyPath:@"fractionCompleted"];
       } @catch (NSException *exception) {}
       objc_setAssociatedObject(cell, kProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    
    // Obtain NSProgress for this row, or create a dummy if missing.
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
    
    // Associate the progress with the cell.
    objc_setAssociatedObject(cell, kProgressKey, progress, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(progress, kCellKey, cell, OBJC_ASSOCIATION_ASSIGN);
    [progress addObserver:self forKeyPath:@"fractionCompleted"
                options:(NSKeyValueObservingOptionNew | NSKeyValueObservingOptionInitial)
                context:CellProgressObserverContext];
    
    // Instead of showing percentage, we display "Done" when finished.
    cell.detailTextLabel.text = progress.finished ? @"Done" : @"";
    cell.accessoryType = progress.finished ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    
    return cell;
}

@end
