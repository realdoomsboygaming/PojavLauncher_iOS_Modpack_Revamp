#import <Foundation/Foundation.h>
#import "ModpackAPI.h"

@interface CurseForgeAPI : ModpackAPI

- (instancetype)initWithAPIKey:(NSString *)apiKey;
- (void)searchModWithFilters:(NSDictionary *)searchFilters
         previousPageResult:(NSMutableArray *)prevResult
                 completion:(void (^)(NSMutableArray * _Nullable results, NSError * _Nullable error))completion;
- (void)loadDetailsOfMod:(NSMutableDictionary *)item
              completion:(void (^)(NSError * _Nullable error))completion;
- (void)installModpackFromDetail:(NSDictionary *)modDetail
                         atIndex:(NSUInteger)selectedVersion
                      completion:(void (^)(NSError * _Nullable error))completion;

/// The parent view controller is used for presenting dialogs (if needed)
@property (nonatomic, weak) UIViewController *parentViewController;

@end
