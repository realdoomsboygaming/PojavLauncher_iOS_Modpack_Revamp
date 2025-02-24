#import <UIKit/UIKit.h>

@class ModpackAPI;

@interface MinecraftResourceDownloadTask : NSObject

@property NSProgress *progress, *textProgress;
@property NSMutableArray *fileList, *progressList;
@property NSMutableDictionary *metadata;
@property (nonatomic, copy) void(^handleError)(void);

// Creates and returns a download task.
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url
                                            size:(NSUInteger)size
                                             sha:(NSString *)sha
                                         altName:(NSString *)altName
                                           toPath:(NSString *)path;

// Finishes the download with an error message.
- (void)finishDownloadWithErrorString:(NSString *)error;

// Downloads the entire version.
- (void)downloadVersion:(NSDictionary *)version;

// Downloads a modpack from the API.
- (void)downloadModpackFromAPI:(ModpackAPI *)api detail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion;

// public method to signal finalization of downloads
- (void)finalizeDownloads;

@end
