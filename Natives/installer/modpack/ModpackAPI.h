#import <Foundation/Foundation.h>
#import "ModpackUtils.h"
#import "UnzipKit.h"

@class MinecraftResourceDownloadTask;

@interface ModpackAPI : NSObject

@property (nonatomic) NSString *baseURL;
@property (nonatomic) NSError *lastError;
@property (nonatomic) BOOL reachedLastPage;

/// Initialize with a base URL string
- (instancetype)initWithURL:(NSString *)url;

/// Perform a search with the given filters
- (NSMutableArray *)searchModWithFilters:(NSDictionary *)filters
                      previousPageResult:(NSMutableArray *)prevResult;

/// Load details for a mod or modpack item in place
- (void)loadDetailsOfMod:(NSMutableDictionary *)item;

/// Install a modpack from a detail dict, picking index in the version arrays
- (void)installModpackFromDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion;

/// Submits download tasks from the .mrpack or .zip package to the downloader
- (void)downloader:(MinecraftResourceDownloadTask *)downloader
submitDownloadTasksFromPackage:(NSString *)packagePath
            toPath:(NSString *)destPath;

/// GET request to “endpoint”
- (id)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params;

@end
