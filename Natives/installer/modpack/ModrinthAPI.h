#import <Foundation/Foundation.h>
#import "ModpackAPI.h"

NS_ASSUME_NONNULL_BEGIN

@interface ModrinthAPI : ModpackAPI

- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, id> *)searchFilters previousPageResult:(NSMutableArray *)modrinthSearchResult;
- (void)loadDetailsOfMod:(NSMutableDictionary *)item completion:(void (^)(NSError *error))completion;

@end

NS_ASSUME_NONNULL_END
