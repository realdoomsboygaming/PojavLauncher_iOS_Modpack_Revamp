#import "MinecraftResourceDownloadTask.h"
#import "ModrinthAPI.h"
#import "PLProfiles.h"

@implementation ModrinthAPI

- (instancetype)init {
    self = [super initWithURL:@"https://api.modrinth.com/v2"];
    return self;
}

- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, id> *)searchFilters previousPageResult:(NSMutableArray *)modrinthSearchResult {
    int limit = 50;
    NSMutableString *facetString = [NSMutableString new];
    [facetString appendString:@"["];
    [facetString appendFormat:@"[\"project_type:%@\"]", [searchFilters[@"isModpack"] boolValue] ? @"modpack" : @"mod"];
    if ([searchFilters[@"mcVersion"] length] > 0) {
        [facetString appendFormat:@",[\"versions:%@\"]", searchFilters[@"mcVersion"]];
    }
    [facetString appendString:@"]"];
    NSDictionary *params = @{
        @"facets": facetString,
        @"query": [searchFilters[@"name"] stringByReplacingOccurrencesOfString:@" " withString:@"+"],
        @"limit": @(limit),
        @"index": @"relevance",
        @"offset": @(modrinthSearchResult.count)
    };
    NSDictionary *response = [self getEndpoint:@"search" params:params];
    if (!response) {
        NSLog(@"ModrinthAPI.searchModWithFilters: No response returned");
        return nil;
    }
    NSMutableArray *result = modrinthSearchResult ?: [NSMutableArray new];
    for (NSDictionary *hit in response[@"hits"]) {
        BOOL isModpack = [hit[@"project_type"] isEqualToString:@"modpack"];
        [result addObject:[@{
            @"apiSource": @(1),
            @"isModpack": @(isModpack),
            @"id": hit[@"project_id"],
            @"title": hit[@"title"],
            @"description": hit[@"description"],
            @"imageUrl": hit[@"icon_url"]
        } mutableCopy]];
    }
    self.reachedLastPage = result.count >= [response[@"total_hits"] unsignedLongValue];
    return result;
}

// Backward compatibility: call the asynchronous version with nil completion.
- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    [self loadDetailsOfMod:item completion:nil];
}

// Synchronous version for use on background threads.
- (void)loadDetailsOfModSync:(NSMutableDictionary *)item {
    NSArray *response = [self getEndpoint:[NSString stringWithFormat:@"project/%@/version", item[@"id"]] params:@{}];
    if (!response) {
        NSLog(@"loadDetailsOfModSync: No response for mod id %@", item[@"id"]);
        return;
    }
    NSMutableArray *versionNames = [NSMutableArray new];
    NSMutableArray *gameVersionsArray = [NSMutableArray new]; // Each element will be an array of supported game_versions.
    NSMutableArray *versionUrls = [NSMutableArray new];
    NSMutableArray *versionSizes = [NSMutableArray new];
    NSMutableArray *versionHashes = [NSMutableArray new];
    
    for (NSDictionary *versionDict in response) {
        NSString *name = versionDict[@"name"] ?: @"";
        NSArray *supportedGameVersions = versionDict[@"game_versions"] ?: @[];
        NSDictionary *file = [versionDict[@"files"] firstObject];
        NSString *url = file[@"url"] ?: @"";
        NSNumber *size = file[@"size"] ?: @0;
        NSDictionary *hashes = file[@"hashes"];
        NSString *sha1 = hashes[@"sha1"] ?: @"";
        
        [versionNames addObject:name];
        [gameVersionsArray addObject:supportedGameVersions];
        [versionUrls addObject:url];
        [versionSizes addObject:size];
        [versionHashes addObject:sha1];
    }
    item[@"versionNames"] = versionNames;
    item[@"gameVersions"] = gameVersionsArray;
    item[@"versionUrls"] = versionUrls;
    item[@"versionSizes"] = versionSizes;
    item[@"versionHashes"] = versionHashes;
    item[@"versionDetailsLoaded"] = @(YES);
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item completion:(void (^)(NSError *error))completion {
    NSString *endpoint = [NSString stringWithFormat:@"project/%@/version", item[@"id"]];
    [self getEndpoint:endpoint params:@{} completion:^(id response, NSError *error) {
        if (!response) {
            NSLog(@"loadDetailsOfMod: No response for mod id %@, error: %@", item[@"id"], error);
            if (completion) completion(error);
            return;
        }
        if (![response isKindOfClass:[NSArray class]]) {
            NSLog(@"loadDetailsOfMod: Unexpected response type: %@", [response class]);
            if (completion) completion([NSError errorWithDomain:@"ModrinthAPIErrorDomain" code:0 userInfo:@{NSLocalizedDescriptionKey:@"Unexpected response format"}]);
            return;
        }
        NSMutableArray *versionNames = [NSMutableArray new];
        NSMutableArray *gameVersionsArray = [NSMutableArray new];
        NSMutableArray *versionUrls = [NSMutableArray new];
        NSMutableArray *versionSizes = [NSMutableArray new];
        NSMutableArray *versionHashes = [NSMutableArray new];
        
        for (NSDictionary *versionDict in response) {
            NSString *name = versionDict[@"name"] ?: @"";
            NSArray *supportedGameVersions = versionDict[@"game_versions"] ?: @[];
            NSDictionary *file = [versionDict[@"files"] firstObject];
            if (!file) {
                NSLog(@"loadDetailsOfMod: Missing file info for version %@", versionDict);
                continue;
            }
            NSString *url = file[@"url"] ?: @"";
            NSNumber *size = file[@"size"] ?: @0;
            NSDictionary *hashes = file[@"hashes"];
            NSString *sha1 = hashes[@"sha1"] ?: @"";
            
            [versionNames addObject:name];
            [gameVersionsArray addObject:supportedGameVersions];
            [versionUrls addObject:url];
            [versionSizes addObject:size];
            [versionHashes addObject:sha1];
        }
        
        item[@"versionNames"] = versionNames;
        item[@"gameVersions"] = gameVersionsArray;
        item[@"versionUrls"] = versionUrls;
        item[@"versionSizes"] = versionSizes;
        item[@"versionHashes"] = versionHashes;
        item[@"versionDetailsLoaded"] = @(YES);
        NSLog(@"loadDetailsOfMod: Loaded %lu versions for mod %@", (unsigned long)versionNames.count, item[@"id"]);
        if (completion) completion(nil);
    }];
}

// New method for installing individual mods.
// Posts a notification named "InstallMod" with mod details and selected version index.
- (void)installModFromDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion {
    NSDictionary *userInfo = @{@"detail": modDetail, @"index": @(selectedVersion)};
    [[NSNotificationCenter defaultCenter] postNotificationName:@"InstallMod" object:self userInfo:userInfo];
}

@end
