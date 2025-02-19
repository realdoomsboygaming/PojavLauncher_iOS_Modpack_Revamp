#import <Foundation/Foundation.h>
#import "MinecraftResourceDownloadTask.h"

@interface CurseForgeAPI : NSObject
@property (nonatomic) BOOL reachedLastPage;
@property (nonatomic) NSInteger previousOffset;
@property (nonatomic, strong) NSString *lastSearchTerm;
@property (nonatomic, strong) NSString *apiKey;
@property (nonatomic, strong) NSError *lastError;

- (instancetype)initWithAPIKey:(NSString *)apiKey;
- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, id> *)searchFilters previousPageResult:(NSMutableArray *)previousResults;
- (void)installModpackFromDetail:(NSDictionary *)detail atIndex:(NSInteger)index;
- (void)loadDetailsOfMod:(NSMutableDictionary *)item;
@end
