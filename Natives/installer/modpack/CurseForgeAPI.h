#ifndef CurseForgeAPI_h
#define CurseForgeAPI_h

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>  // Needed for UIViewController

@class MinecraftResourceDownloadTask;  // Forward declaration

@interface CurseForgeAPI : NSObject

@property (nonatomic, strong, readonly) NSString *apiKey;
@property (nonatomic, strong) NSError *lastError;
@property (nonatomic, assign) NSInteger previousOffset;
@property (nonatomic, assign) BOOL reachedLastPage;
@property (nonatomic, strong) NSString *lastSearchTerm;

// This property will be set by the view controller so that SFSafariViewController can be presented.
@property (nonatomic, weak) UIViewController *parentViewController;

/// Initialize with a CurseForge API key
- (instancetype)initWithAPIKey:(NSString *)apiKey;

/// Make a GET request to some endpoint, returning a parsed JSON object
- (id)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params;

/// Search for a mod or modpack with the given filters
- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, id> *)searchFilters
                      previousPageResult:(NSMutableArray *)previousResults;

/// Pre-load version details (files) of a mod or modpack item
- (void)loadDetailsOfMod:(NSMutableDictionary *)item;

/// Install (download) a modpack from the detail dictionary at index in version arrays
- (void)installModpackFromDetail:(NSDictionary *)detail atIndex:(NSInteger)index;

/// Submit download tasks from the downloaded modpack package
- (void)downloader:(MinecraftResourceDownloadTask *)downloader
submitDownloadTasksFromPackage:(NSString *)packagePath
            toPath:(NSString *)destPath;

/// Start the pending subfile downloads (to be triggered when the user taps "Play")
- (void)startPendingDownload;

@end

#endif /* CurseForgeAPI_h */
