#import <Foundation/Foundation.h>
#import "ModpackAPI.h"
NS_ASSUME_NONNULL_BEGIN

@interface ModrinthAPI : ModpackAPI

- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, id> *)searchFilters previousPageResult:(NSMutableArray *)modrinthSearchResult;

// Synchronous version (for use on a background thread)
- (void)loadDetailsOfModSync:(NSMutableDictionary *)item;

// Asynchronous version (calls completion on the main thread)
- (void)loadDetailsOfMod:(NSMutableDictionary *)item completion:(void (^)(NSError *error))completion;

// New mod installation method (for mods, not modpacks)
- (void)installModFromDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion;

@end

NS_ASSUME_NONNULL_END
