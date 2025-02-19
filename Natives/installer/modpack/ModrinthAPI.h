#import <Foundation/Foundation.h>
#import "MinecraftResourceDownloadTask.h"
#import <AFNetworking/AFHTTPSessionManager.h>

@interface ModrinthAPI : AFHTTPSessionManager

@property (nonatomic) BOOL reachedLastPage;
@property (nonatomic, strong) NSString *lastSearchTerm;
@property (nonatomic, strong) NSError *lastError;

- (instancetype)init;
- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, NSString *> *)searchFilters previousPageResult:(NSMutableArray *)modrinthSearchResult;
- (void)loadDetailsOfMod:(NSMutableDictionary *)item;
- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath;

@end
