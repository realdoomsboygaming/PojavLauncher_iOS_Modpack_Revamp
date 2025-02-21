#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import "ModpackAPI.h"

NS_ASSUME_NONNULL_BEGIN

@interface CurseForgeAPI : ModpackAPI
- (instancetype)initWithAPIKey:(NSString *)apiKey NS_DESIGNATED_INITIALIZER;
- (void)searchModWithFilters:(NSDictionary *)searchFilters previousPageResult:(NSMutableArray *)prevResult completion:(void (^)(NSMutableArray * _Nullable results, NSError * _Nullable error))completion;
- (void)loadDetailsOfMod:(NSMutableDictionary *)item completion:(void (^)(NSError * _Nullable error))completion;
- (void)installModpackFromDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion completion:(void (^)(NSError * _Nullable error))completion;
@property (nonatomic, weak, nullable) UIViewController *parentViewController;
@end

NS_ASSUME_NONNULL_END
