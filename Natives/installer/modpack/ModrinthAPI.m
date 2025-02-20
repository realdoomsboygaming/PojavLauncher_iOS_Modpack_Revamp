#import "MinecraftResourceDownloadTask.h"
#import "ModrinthAPI.h"
#import "PLProfiles.h"
#import "UZKArchive.h"
#import "ModpackUtils.h"

@implementation ModrinthAPI

// Initialize with the base URL for Modrinth
- (instancetype)init {
    return [super initWithURL:@"https://api.modrinth.com/v2"];
}

// Search for mods or modpacks
- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, NSString *> *)searchFilters
                       previousPageResult:(NSMutableArray *)modrinthSearchResult
{
    int limit = 50;
    
    // Build the facets string for Modrinth
    NSMutableString *facetString = [NSMutableString new];
    [facetString appendString:@"["];
    [facetString appendFormat:@"[\"project_type:%@\"]", (searchFilters[@"isModpack"].boolValue ? @"modpack" : @"mod")];
    if (searchFilters[@"mcVersion"].length > 0) {
        [facetString appendFormat:@",[\"versions:%@\"]", searchFilters[@"mcVersion"]];
    }
    [facetString appendString:@"]"];
    
    // Prepare parameters
    NSDictionary *params = @{
        @"facets": facetString,
        @"query": [searchFilters[@"name"] ?: @"" stringByReplacingOccurrencesOfString:@" " withString:@"+"],
        @"limit": @(limit),
        @"index": @"relevance",
        @"offset": @(modrinthSearchResult.count ?: 0)
    };
    
    NSDictionary *response = [self getEndpoint:@"search" params:params];
    if (!response) {
        return nil;
    }
    
    NSMutableArray *result = modrinthSearchResult ?: [NSMutableArray new];
    for (NSDictionary *hit in response[@"hits"]) {
        BOOL isModpack = [hit[@"project_type"] isEqualToString:@"modpack"];
        [result addObject:@{
            @"apiSource": @(1),  // 1 indicating Modrinth
            @"isModpack": @(isModpack),
            @"id": hit[@"project_id"] ?: @"",
            @"title": hit[@"title"] ?: @"",
            @"description": hit[@"description"] ?: @"",
            @"imageUrl": hit[@"icon_url"] ?: @""
        }.mutableCopy];
    }
    
    NSUInteger totalHits = [response[@"total_hits"] unsignedLongValue];
    self.reachedLastPage = (result.count >= totalHits);
    
    return result;
}

// Load additional details about a specific mod or modpack
- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    if (!item[@"id"]) return;
    
    NSString *endpoint = [NSString stringWithFormat:@"project/%@/version", item[@"id"]];
    NSArray *response = [self getEndpoint:endpoint params:nil];
    if (!response || ![response isKindOfClass:[NSArray class]]) {
        return;
    }
    
    NSArray<NSString *> *names = [response valueForKey:@"name"];
    NSMutableArray<NSString *> *mcNames = [NSMutableArray arrayWithCapacity:response.count];
    NSMutableArray<NSString *> *urls    = [NSMutableArray arrayWithCapacity:response.count];
    NSMutableArray<NSString *> *hashes  = [NSMutableArray arrayWithCapacity:response.count];
    NSMutableArray<NSNumber *> *sizes   = [NSMutableArray arrayWithCapacity:response.count];
    
    [response enumerateObjectsUsingBlock:^(NSDictionary *version, NSUInteger i, BOOL *stop) {
        if (![version isKindOfClass:[NSDictionary class]]) {
            return;
        }
        NSDictionary *file = [version[@"files"] firstObject];
        if (![file isKindOfClass:[NSDictionary class]]) {
            return;
        }
        
        NSString *someMC = [[version objectForKey:@"game_versions"] firstObject] ?: @"";
        [mcNames addObject:someMC];
        
        NSNumber *fileSize = file[@"size"] ?: @0;
        [sizes addObject:fileSize];
        
        NSString *fileURL = file[@"url"] ?: @"";
        [urls addObject:fileURL];
        
        NSDictionary *hashesMap = file[@"hashes"];
        NSString *sha1 = hashesMap[@"sha1"] ?: @"";
        [hashes addObject:sha1];
    }];
    
    item[@"versionNames"] = names ?: @[];
    item[@"mcVersionNames"] = mcNames;
    item[@"versionSizes"] = sizes;
    item[@"versionUrls"] = urls;
    item[@"versionHashes"] = hashes;
    item[@"versionDetailsLoaded"] = @(YES);
}

// Implement installModpackFromDetail:atIndex: for Modrinth
- (void)installModpackFromDetail:(NSDictionary *)detail atIndex:(NSInteger)index {
    NSArray *urls = detail[@"versionUrls"];
    if (![urls isKindOfClass:[NSArray class]] || index < 0 || index >= urls.count) {
        NSLog(@"[ModrinthAPI] No valid versionUrls or invalid index %ld", (long)index);
        return;
    }
    NSString *mrpackUrlString = urls[index];
    if (mrpackUrlString.length == 0) {
        NSLog(@"[ModrinthAPI] Empty mrpackUrl at index %ld", (long)index);
        return;
    }
    NSURL *mrpackURL = [NSURL URLWithString:mrpackUrlString];
    if (!mrpackURL) {
        NSLog(@"[ModrinthAPI] Could not parse mrpack url: %@", mrpackUrlString);
        return;
    }
    
    // Post a notification so that the download task can be initiated
    NSDictionary *userInfo = @{
        @"detail": detail,
        @"index": @(index),
        @"source": @(1)  // 1 indicating Modrinth
    };
    [[NSNotificationCenter defaultCenter] postNotificationName:@"InstallModpack"
                                                        object:self
                                                      userInfo:userInfo];
}

// Submit download tasks from a .mrpack package to the provided MinecraftResourceDownloadTask
- (void)downloader:(MinecraftResourceDownloadTask *)downloader
submitDownloadTasksFromPackage:(NSString *)packagePath
            toPath:(NSString *)destPath
{
    NSError *error;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:
           [NSString stringWithFormat:@"Failed to open modpack package: %@", error.localizedDescription]];
        return;
    }
    
    NSData *indexData = [archive extractDataFromFile:@"modrinth.index.json" error:&error];
    NSDictionary *indexDict = nil;
    if (indexData && !error) {
        indexDict = [NSJSONSerialization JSONObjectWithData:indexData options:0 error:&error];
    }
    if (!indexDict || error) {
        [downloader finishDownloadWithErrorString:
           [NSString stringWithFormat:@"Failed to parse modrinth.index.json: %@", error.localizedDescription]];
        return;
    }
    
    NSArray *fileList = indexDict[@"files"];
    if (![fileList isKindOfClass:[NSArray class]]) {
        [downloader finishDownloadWithErrorString:@"Malformed modrinth.index.json: no 'files' array."];
        return;
    }
    downloader.progress.totalUnitCount = fileList.count;
    
    for (NSDictionary *indexFile in fileList) {
        NSString *url = [indexFile[@"downloads"] firstObject] ?: @"";
        NSString *sha = indexFile[@"hashes"][@"sha1"] ?: @"";
        NSString *path = [destPath stringByAppendingPathComponent:(indexFile[@"path"] ?: @"")];
        NSUInteger size = [indexFile[@"fileSize"] unsignedLongLongValue];
        
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:url
                                                                  size:size
                                                                   sha:sha
                                                               altName:nil
                                                                toPath:path];
        if (task) {
            [downloader.fileList addObject:indexFile[@"path"] ?: @""];
            [task resume];
        } else if (!downloader.progress.cancelled) {
            downloader.progress.completedUnitCount++;
        } else {
            return;
        }
    }
    
    [ModpackUtils archive:archive extractDirectory:@"overrides" toPath:destPath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:
           [NSString stringWithFormat:@"Failed to extract overrides from modpack package: %@", error.localizedDescription]];
        return;
    }
    [ModpackUtils archive:archive extractDirectory:@"client-overrides" toPath:destPath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:
           [NSString stringWithFormat:@"Failed to extract client-overrides from modpack package: %@", error.localizedDescription]];
        return;
    }
    
    [[NSFileManager defaultManager] removeItemAtPath:packagePath error:nil];
    
    NSDictionary<NSString *, NSString *> *depInfo = [ModpackUtils infoForDependencies:indexDict[@"dependencies"]];
    if (depInfo[@"json"]) {
        NSString *jsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json",
                              getenv("POJAV_GAME_DIR"), depInfo[@"id"]];
        NSURLSessionDownloadTask *depTask =
          [downloader createDownloadTask:depInfo[@"json"] size:0 sha:nil altName:nil toPath:jsonPath];
        [depTask resume];
    }
    
    NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
    NSData *iconData = [NSData dataWithContentsOfFile:tmpIconPath];
    NSString *base64Icon = iconData ? [iconData base64EncodedStringWithOptions:0] : @"";
    
    if ([indexDict[@"name"] isKindOfClass:[NSString class]]) {
        PLProfiles.current.profiles[indexDict[@"name"]] = [@{
            @"gameDir": [NSString stringWithFormat:@"./custom_gamedir/%@", destPath.lastPathComponent],
            @"name": indexDict[@"name"],
            @"lastVersionId": depInfo[@"id"] ?: @"",
            @"icon": [NSString stringWithFormat:@"data:image/png;base64,%@", base64Icon]
        } mutableCopy];
        PLProfiles.current.selectedProfileName = indexDict[@"name"];
    }
}

@end
