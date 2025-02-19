#import <Foundation/Foundation.h>
#import "ModpackAPI.h"

@interface ModrinthAPI : ModpackAPI
- (void)installModpackFromDetail:(NSDictionary *)detail atIndex:(NSInteger)index;
@end
