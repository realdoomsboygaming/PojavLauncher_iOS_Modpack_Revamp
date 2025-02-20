#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@class MinecraftResourceDownloadTask;

NS_ASSUME_NONNULL_BEGIN

@interface CurseForgeAPI : NSObject

@property (nonatomic, strong, readonly) NSString *apiKey;
@property (nonatomic, strong, nullable) NSError *lastError;
@property (nonatomic, assign) NSInteger previousOffset;
@property (nonatomic, assign) BOOL reachedLastPage;
@property (nonatomic, strong, nullable) NSString *lastSearchTerm;

// This property will be set by the view controller so that SFSafariViewController can be presented.
@property (nonatomic, weak, nullable) UIViewController *parentViewController;

/// Initialize with a CurseForge API key
- (instancetype)initWithAPIKey:(NSString *)apiKey;

/// Asynchronous GET request to an endpoint, returning parsed JSON in the completion block.
- (void)getEndpoint:(NSString *)endpoint
             params:(NSDictionary *)params
         completion:(void(^)(id _Nullable result, NSError * _Nullable error))completion;

/// Asynchronously search for a mod or modpack with the given filters.
- (void)searchModWithFilters:(NSDictionary<NSString *, id> *)searchFilters
         previousPageResult:(NSMutableArray * _Nullable)previousResults
                 completion:(void(^)(NSMutableArray * _Nullable results, NSError * _Nullable error))completion;

/// Asynchronously load details (version info) for a mod or modpack item.
- (void)loadDetailsOfMod:(NSMutableDictionary *)item
              completion:(void(^)(NSError * _Nullable error))completion;

/// Asynchronously install (download) a modpack from the detail dictionary at a given index.
- (void)installModpackFromDetail:(NSDictionary *)detail
                         atIndex:(NSInteger)index
                      completion:(void(^)(NSError * _Nullable error))completion;

/// Submit download tasks from the downloaded modpack package.
/// (This method remains synchronous/unchanged.)
- (void)downloader:(MinecraftResourceDownloadTask *)downloader
submitDownloadTasksFromPackage:(NSString *)packagePath
               toPath:(NSString *)destPath;

/// Start pending subfile downloads (triggered when the user taps "Play").
- (void)startPendingDownload;

@end

NS_ASSUME_NONNULL_END
