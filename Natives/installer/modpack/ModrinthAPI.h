#import <Foundation/Foundation.h>
#import "ModpackAPI.h"
NS_ASSUME_NONNULL_BEGIN

@interface ModrinthAPI : ModpackAPI

- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, id> *)searchFilters previousPageResult:(NSMutableArray *)modrinthSearchResult;
- (void)loadDetailsOfModSync:(NSMutableDictionary *)item;
- (void)loadDetailsOfMod:(NSMutableDictionary *)item completion:(void (^)(NSError *error))completion;
- (void)loadDetailsOfMod:(NSMutableDictionary *)item;
- (void)installModFromDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion;

@end

NS_ASSUME_NONNULL_END
