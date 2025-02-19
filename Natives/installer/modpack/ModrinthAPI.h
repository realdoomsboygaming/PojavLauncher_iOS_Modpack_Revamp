#import <Foundation/Foundation.h>
#import "ModpackAPI.h"

@interface ModrinthAPI : ModpackAPI

/// Install a Modrinth modpack at the specified index inside the detail dictionary
- (void)installModpackFromDetail:(NSDictionary *)detail atIndex:(NSInteger)index;

@end
