// Natives/modpack/CurseForgeAPI.h
#import <Foundation/Foundation.h>

@interface CurseForgeAPI : NSObject

- (instancetype)initWithAPIKey:(NSString *)apiKey;
- (void)searchModsWithFilters:(NSDictionary *)filters previousPageResult:(NSArray *)previousResults completion:(void (^)(NSArray *results, BOOL hasMore, NSError *error))completion;
- (void)getModDetails:(NSString *)modId completion:(void (^)(NSDictionary *details, NSError *error))completion;
- (void)installModpackFromDetail:(NSDictionary *)detail atIndex:(NSInteger)index completion:(void (^)(BOOL success, NSError *error))completion;

@end
