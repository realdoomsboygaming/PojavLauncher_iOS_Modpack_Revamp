#import <dlfcn.h>
#import <objc/runtime.h>
#import "DownloadProgressViewController.h"

// Use static const pointers as keys for associated objects.
static const void *kProgressKey = &kProgressKey;
static const void *kCellKey = &kCellKey;
static void *CellProgressObserverContext = &CellProgressObserverContext;
static void *TotalProgressObserverContext = &TotalProgressObserverContext;

@interface DownloadProgressViewController ()
@property (nonatomic) NSInteger fileListCount;
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
    self.tableView.allowsSelection = YES;
    // Cells will use accessoryType (checkmark) instead of a custom progress view.
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.task.textProgress addObserver:self
                             forKeyPath:@"fractionCompleted"
                                options:(NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew)
                                context:TotalProgressObserverContext];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    @try {
        [self.task.textProgress removeObserver:self forKeyPath:@"fractionCompleted"];
    } @catch (NSException *exception) {}
}

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
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0f%%", progress.fractionCompleted * 100];
            cell.accessoryType = progress.finished ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        });
    } else if (context == TotalProgressObserverContext) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.title = [NSString stringWithFormat:@"Downloading: %.0f%%", self.task.textProgress.fractionCompleted * 100];
            if (self.fileListCount != self.task.fileList.count) {
                [self.tableView reloadData];
            }
            self.fileListCount = self.task.fileList.count;
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
    
    // Safely obtain the file name.
    NSString *fileName = @"";
    if (indexPath.row < self.task.fileList.count) {
       fileName = self.task.fileList[indexPath.row];
    }
    cell.textLabel.text = fileName;
    
    // Remove any previous observer and associated progress.
    NSProgress *oldProgress = objc_getAssociatedObject(cell, kProgressKey);
    if (oldProgress) {
       @try {
           [oldProgress removeObserver:self forKeyPath:@"fractionCompleted"];
       } @catch (NSException *exception) {}
       objc_setAssociatedObject(cell, kProgressKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    
    // Obtain NSProgress for this row, or create a dummy if missing.
    NSProgress *progress = nil;
    if (indexPath.row < self.task.progressList.count) {
       progress = self.task.progressList[indexPath.row];
    } else {
       progress = [NSProgress progressWithTotalUnitCount:1];
       progress.completedUnitCount = 0;
    }
    
    // Associate the progress with the cell using our static key.
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
