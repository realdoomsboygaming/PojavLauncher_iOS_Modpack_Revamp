#import "MinecraftResourceDownloadTask.h"
#import "ModrinthAPI.h"
#import "PLProfiles.h"
#import "ModpackUtils.h"

@implementation ModrinthAPI

- (instancetype)init {
    return [super initWithURL:@"https://api.modrinth.com/v2"];
}

- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, NSString *> *)searchFilters previousPageResult:(NSMutableArray *)modrinthSearchResult {
    int limit = 50;

    NSMutableString *facetString = [NSMutableString stringWithString:@"["];
    [facetString appendFormat:@"[\"project_type:%@\"]", ([searchFilters[@"isModpack"] boolValue] ? @"modpack" : @"mod")];
    if (searchFilters[@"mcVersion"].length > 0) {
        [facetString appendFormat:@",[\"versions:%@\"]", searchFilters[@"mcVersion"]];
    }
    [facetString appendString:@"]"];

    NSDictionary *params = @{
        @"facets": facetString,
        @"query": (searchFilters[@"name"] ? [searchFilters[@"name"] stringByReplacingOccurrencesOfString:@" " withString:@"+"] : @""),
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
        NSMutableDictionary *entry = [@{
            @"apiSource": @(1),
            @"isModpack": @(isModpack),
            @"id": hit[@"project_id"] ?: @"",
            @"title": hit[@"title"] ?: @"",
            @"description": hit[@"description"] ?: @"",
            @"imageUrl": hit[@"icon_url"] ?: @""
        } mutableCopy];
        [result addObject:entry];
    }
    self.reachedLastPage = (result.count >= [response[@"total_hits"] unsignedIntegerValue]);
    return result;
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    NSArray *response = [self getEndpoint:[NSString stringWithFormat:@"project/%@/version", item[@"id"]] params:nil];
    if (!response) {
        return;
    }
    NSArray *names = [response valueForKey:@"name"];
    NSMutableArray *mcNames = [NSMutableArray arrayWithCapacity:response.count];
    NSMutableArray *urls = [NSMutableArray arrayWithCapacity:response.count];
    NSMutableArray *hashes = [NSMutableArray arrayWithCapacity:response.count];
    NSMutableArray *sizes = [NSMutableArray arrayWithCapacity:response.count];

    [response enumerateObjectsUsingBlock:^(NSDictionary *version, NSUInteger i, BOOL *stop) {
        NSDictionary *file = [version[@"files"] firstObject];
        [mcNames addObject:(version[@"game_versions"] && [version[@"game_versions"] count] > 0 ? version[@"game_versions"][0] : @"")];
        [sizes addObject:file[@"size"] ?: @0];
        [urls addObject:file[@"url"] ?: @""];
        NSDictionary *hashesMap = file[@"hashes"];
        [hashes addObject:(hashesMap[@"sha1"] ?: @"")];
    }];
    item[@"versionNames"] = names;
    item[@"mcVersionNames"] = mcNames;
    item[@"versionSizes"] = sizes;
    item[@"versionUrls"] = urls;
    item[@"versionHashes"] = hashes;
    item[@"versionDetailsLoaded"] = @(YES);
}

- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath {
    NSError *error = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to open modpack package: %@", error.localizedDescription]];
        return;
    }

    NSData *indexData = [archive extractDataFromFile:@"modrinth.index.json" error:&error];
    NSDictionary *indexDict = [NSJSONSerialization JSONObjectWithData:indexData options:0 error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to parse modrinth.index.json: %@", error.localizedDescription]];
        return;
    }

    // Ensure unique file paths are counted
    NSArray *filesArray = indexDict[@"files"];
    NSMutableSet *processedFiles = [NSMutableSet new]; // Track unique files
    downloader.progress.totalUnitCount = 0;

    for (NSDictionary *indexFile in filesArray) {
        NSString *filePath = indexFile[@"path"] ?: @"";
        if (filePath.length == 0) {
            NSLog(@"[ModrinthAPI] Skipping file with empty path.");
            continue;
        }
        
        // Skip if file has already been processed
        if ([processedFiles containsObject:filePath]) {
            NSLog(@"[ModrinthAPI] Skipping duplicate file: %@", filePath);
            continue;
        }
        
        [processedFiles addObject:filePath]; // Mark file as processed
        downloader.progress.totalUnitCount++; // Only count unique files

        NSString *url = [indexFile[@"downloads"] firstObject] ?: @"";
        NSString *sha = indexFile[@"hashes"][@"sha1"] ?: @"";
        NSString *path = [destPath stringByAppendingPathComponent:filePath];
        NSUInteger size = [indexFile[@"fileSize"] unsignedLongLongValue];

        NSURLSessionDownloadTask *task = [downloader createDownloadTask:url size:size sha:sha altName:nil toPath:path];
        if (task) {
            @synchronized(downloader.fileList) {
                if (![downloader.fileList containsObject:filePath]) {
                    [downloader.fileList addObject:filePath];
                }
            }
            [task resume];
        } else if (!downloader.progress.cancelled) {
            downloader.progress.completedUnitCount++;
        } else {
            return;
        }
    }

    [ModpackUtils archive:archive extractDirectory:@"overrides" toPath:destPath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract overrides from modpack package: %@", error.localizedDescription]];
        return;
    }

    [ModpackUtils archive:archive extractDirectory:@"client-overrides" toPath:destPath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract client-overrides from modpack package: %@", error.localizedDescription]];
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
    NSDictionary *profileInfo = @{
        @"gameDir": [NSString stringWithFormat:@"./custom_gamedir/%@", destPath.lastPathComponent],
        @"name": indexDict[@"name"] ?: @"",
        @"lastVersionId": depInfo[@"id"] ?: @"",
        @"icon": [NSString stringWithFormat:@"data:image/png;base64,%@",
                  [[NSData dataWithContentsOfFile:tmpIconPath] base64EncodedStringWithOptions:0]]
    };
    PLProfiles.current.profiles[indexDict[@"name"]] = profileInfo;
}

@end
