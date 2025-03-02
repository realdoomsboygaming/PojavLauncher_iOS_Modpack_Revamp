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

- (void)loadDetailsOfModSync:(NSMutableDictionary *)item {
    NSArray *response = [self getEndpoint:[NSString stringWithFormat:@"project/%@/version", item[@"id"]] params:@{}];
    if (!response) {
        return;
    }
    NSArray<NSString *> *names = [response valueForKey:@"name"];
    NSMutableArray *mcNames = [NSMutableArray new];
    NSMutableArray *urls = [NSMutableArray new];
    NSMutableArray *hashes = [NSMutableArray new];
    NSMutableArray *sizes = [NSMutableArray new];
    [response enumerateObjectsUsingBlock:^(NSDictionary *version, NSUInteger i, BOOL *stop) {
        NSDictionary *file = [version[@"files"] firstObject];
        [mcNames addObject:[version[@"game_versions"] firstObject]];
        [sizes addObject:file[@"size"]];
        [urls addObject:file[@"url"]];
        NSDictionary *hashesMap = file[@"hashes"];
        [hashes addObject:hashesMap[@"sha1"] ?: [NSNull null]];
    }];
    item[@"versionNames"] = names;
    item[@"mcVersionNames"] = mcNames;
    item[@"versionSizes"] = sizes;
    item[@"versionUrls"] = urls;
    item[@"versionHashes"] = hashes;
    item[@"versionDetailsLoaded"] = @(YES);
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item completion:(void (^)(NSError *error))completion {
    NSString *endpoint = [NSString stringWithFormat:@"project/%@/version", item[@"id"]];
    [self getEndpoint:endpoint params:@{} completion:^(id response, NSError *error) {
        if (!response) {
            if (completion) completion(error);
            return;
        }
        NSArray *names = [response valueForKey:@"name"];
        NSMutableArray *mcNames = [NSMutableArray new];
        NSMutableArray *urls = [NSMutableArray new];
        NSMutableArray *hashes = [NSMutableArray new];
        NSMutableArray *sizes = [NSMutableArray new];
        [response enumerateObjectsUsingBlock:^(NSDictionary *version, NSUInteger i, BOOL *stop) {
            NSDictionary *file = [version[@"files"] firstObject];
            [mcNames addObject:[version[@"game_versions"] firstObject]];
            [sizes addObject:file[@"size"]];
            [urls addObject:file[@"url"]];
            NSDictionary *hashesMap = file[@"hashes"];
            [hashes addObject:hashesMap[@"sha1"] ?: [NSNull null]];
        }];
        item[@"versionNames"] = names;
        item[@"mcVersionNames"] = mcNames;
        item[@"versionSizes"] = sizes;
        item[@"versionUrls"] = urls;
        item[@"versionHashes"] = hashes;
        item[@"versionDetailsLoaded"] = @(YES);
        if (completion) completion(nil);
    }];
}

@end
