#import <Foundation/Foundation.h>
#import "ModpackAPI.h"

@interface CurseForgeAPI : ModpackAPI

- (instancetype)initWithAPIKey:(NSString *)apiKey;
- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, id> *)searchFilters previousPageResult:(NSMutableArray *)previousResults;
- (void)loadDetailsOfMod:(NSMutableDictionary *)item;
- (void)installModpackFromDetail:(NSDictionary *)detail atIndex:(NSInteger)index;

@property (nonatomic, strong) NSError *lastError;
@property (nonatomic, assign) BOOL reachedLastPage;
@property (nonatomic, assign) NSInteger previousOffset;

@end
