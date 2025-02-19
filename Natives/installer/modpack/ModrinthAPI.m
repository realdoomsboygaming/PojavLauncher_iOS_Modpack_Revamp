#import "ModrinthAPI.h"
#import "PLProfiles.h"
#import "UZKArchive.h"
#import "ModpackUtils.h"

@implementation ModrinthAPI

- (instancetype)init {
    self = [super init];
    return self;
}

- (id)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params {
    __block id result;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    NSURLComponents *components = [NSURLComponents componentsWithString:[NSString stringWithFormat:@"https://api.modrinth.com/v2/%@", endpoint]];
    components.queryItems = [self queryItemsFromParams:params];
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL];
    [request setValue:@"Mozilla/5.0" forHTTPHeaderField:@"User-Agent"];
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            self.lastError = error;
            dispatch_semaphore_signal(semaphore);
            return;
        }
        
        NSError *jsonError;
        result = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:&jsonError];
        if (jsonError) {
            self.lastError = jsonError;
        }
        dispatch_semaphore_signal(semaphore);
    }];
    
    [task resume];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    return result;
}

- (NSArray<NSURLQueryItem *> *)queryItemsFromParams:(NSDictionary *)params {
    NSMutableArray *queryItems = [NSMutableArray array];
    for (NSString *key in params) {
        [queryItems addObject:[NSURLQueryItem queryItemWithName:key value:[NSString stringWithFormat:@"%@", params[key]]]];
    }
    return queryItems;
}

- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, NSString *> *)searchFilters previousPageResult:(NSMutableArray *)modrinthSearchResult {
    int limit = 50;
    
    NSMutableString *facetString = [NSMutableString new];
    [facetString appendString:@"[[\"project_type:%@\"]]"];
    [facetString replaceOccurrencesOfString:@"%@" withString:(searchFilters[@"isModpack"].boolValue ? @"modpack" : @"mod") options:0 range:NSMakeRange(0, facetString.length)];
    
    if (searchFilters[@"mcVersion"].length > 0) {
        [facetString appendFormat:@",[[\"versions:%@\"]]", searchFilters[@"mcVersion"]];
    }
    
    NSDictionary *params = @{
        @"facets": facetString,
        @"query": [searchFilters[@"name"] stringByReplacingOccurrencesOfString:@" " withString:@"+"],
        @"limit": @(limit),
        @"index": @"relevance",
        @"offset": @(modrinthSearchResult.count)
    };
    
    NSDictionary *response = [self getEndpoint:@"search" params:params];
    if (!response) {
        self.lastError = [NSError errorWithDomain:@"ModrinthAPI" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Failed to fetch results"}];
        return nil;
    }
    
    NSMutableArray *result = modrinthSearchResult ?: [NSMutableArray new];
    for (NSDictionary *hit in response[@"hits"]) {
        BOOL isModpack = [hit[@"project_type"] isEqualToString:@"modpack"];
        [result addObject:@{
            @"apiSource": @(1),
            @"isModpack": @(isModpack),
            @"id": hit[@"project_id"],
            @"title": hit[@"title"],
            @"description": hit[@"description"],
            @"imageUrl": hit[@"icon_url"]
        }.mutableCopy];
    }
    
    self.reachedLastPage = result.count >= [response[@"total_hits"] unsignedLongValue];
    self.lastSearchTerm = searchFilters[@"name"];
    return result;
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    NSArray *response = [self getEndpoint:[NSString stringWithFormat:@"project/%@/version", item[@"id"]] params:nil];
    if (!response) return;
    
    NSArray *names = [response valueForKey:@"name"];
    NSMutableArray *mcNames = [NSMutableArray new];
    NSMutableArray *urls = [NSMutableArray new];
    NSMutableArray *hashes = [NSMutableArray new];
    NSMutableArray *sizes = [NSMutableArray new];
    
    [response enumerateObjectsUsingBlock:^(NSDictionary *version, NSUInteger i, BOOL *stop) {
        NSDictionary *file = [version[@"files"] firstObject];
        NSString *gameVersion = [version[@"game_versions"] firstObject];
        [mcNames addObject:(gameVersion ? gameVersion : @"")];
        NSString *size = file[@"size"];
        [sizes addObject:(size ? size : @"")];
        NSString *url = file[@"url"];
        [urls addObject:(url ? url : @"")];
        NSDictionary *hashesMap = file[@"hashes"];
        NSString *sha1 = hashesMap[@"sha1"];
        [hashes addObject:(sha1 ? sha1 : [NSNull null])];
    }];
    
    item[@"versionNames"] = names;
    item[@"mcVersionNames"] = mcNames;
    item[@"versionSizes"] = sizes;
    item[@"versionUrls"] = urls;
    item[@"versionHashes"] = hashes;
    item[@"versionDetailsLoaded"] = @(YES);
}

- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath {
    NSError *error;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to open modpack package: %@", error.localizedDescription]];
        return;
    }
    
    NSData *indexData = [archive extractDataFromFile:@"modrinth.index.json" error:&error];
    NSDictionary *indexDict = [NSJSONSerialization JSONObjectWithData:indexData options:kNilOptions error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to parse modrinth.index.json: %@", error.localizedDescription]];
        return;
    }
    
    downloader.progress.totalUnitCount = [indexDict[@"files"] count];
    for (NSDictionary *indexFile in indexDict[@"files"]) {
        NSString *url = [indexFile[@"downloads"] firstObject];
        NSString *sha = indexFile[@"hashes"][@"sha1"];
        NSString *path = [destPath stringByAppendingPathComponent:indexFile[@"path"]];
        NSUInteger size = [indexFile[@"fileSize"] unsignedLongLongValue];
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:url size:size sha:sha altName:nil toPath:path];
        if (task) {
            [downloader.fileList addObject:indexFile[@"path"]];
            [task resume];
        } else if (!downloader.progress.cancelled) {
            downloader.progress.completedUnitCount++;
        }
    }
    
    [ModpackUtils archive:archive extractDirectory:@"overrides" toPath:destPath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract overrides: %@", error.localizedDescription]];
        return;
    }
    
    [ModpackUtils archive:archive extractDirectory:@"client-overrides" toPath:destPath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract client-overrides: %@", error.localizedDescription]];
        return;
    }
    
    [[NSFileManager defaultManager] removeItemAtPath:packagePath error:nil];
    
    NSDictionary<NSString *, NSString *> *depInfo = [ModpackUtils infoForDependencies:indexDict[@"dependencies"]];
    if (depInfo[@"json"]) {
        NSString *jsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), depInfo[@"id"]];
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:depInfo[@"json"] size:0 sha:nil altName:nil toPath:jsonPath];
        [task resume];
    }
    
    NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
    PLProfiles.current.profiles[indexDict[@"name"]] = @{
        @"gameDir": [NSString stringWithFormat:@"./custom_gamedir/%@", destPath.lastPathComponent],
        @"name": indexDict[@"name"],
        @"lastVersionId": depInfo[@"id"],
        @"icon": [NSString stringWithFormat:@"data:image/png;base64,%@",
                  [[NSData dataWithContentsOfFile:tmpIconPath] base64EncodedStringWithOptions:0]]
    }.mutableCopy;
    PLProfiles.current.selectedProfileName = indexDict[@"name"];
}

@end
