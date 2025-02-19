#import <Foundation/Foundation.h>
#import "ModpackAPI.h"

@interface CurseForgeAPI : ModpackAPI

@property (nonatomic, strong) NSString *apiKey;
@property (nonatomic, strong) NSError *lastError;
@property (nonatomic, assign) BOOL reachedLastPage;
@property (nonatomic, assign) NSInteger previousOffset;

- (instancetype)init;
- (instancetype)initWithAPIKey:(NSString *)apiKey;
- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, id> *)searchFilters previousPageResult:(NSMutableArray *)previousResults;
- (void)installModpackFromDetail:(NSDictionary *)detail atIndex:(NSInteger)index;
- (void)loadDetailsOfMod:(NSMutableDictionary *)item;

@end
