#import <Foundation/Foundation.h>
#import "MinecraftResourceDownloadTask.h"

@interface ModrinthAPI : NSObject

@property (nonatomic) BOOL reachedLastPage;
@property (nonatomic, strong) NSString *lastSearchTerm;

- (instancetype)init;
- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, NSString *> *)searchFilters previousPageResult:(NSMutableArray *)modrinthSearchResult;
- (void)loadDetailsOfMod:(NSMutableDictionary *)item;
- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath;

@end
