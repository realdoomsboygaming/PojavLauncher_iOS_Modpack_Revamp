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
        // self.lastError is likely set
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

    // Decide if we've reached the last page
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

    // Normally we'd do more robust checks, but we'll mirror your structure:
    NSArray<NSString *> *names = [response valueForKey:@"name"]; // KVC array of each "name"

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
            // Just skip if there's no valid file
            return;
        }

        // Extract MC version
        NSString *someMC = [[version objectForKey:@"game_versions"] firstObject] ?: @"";
        [mcNames addObject:someMC];

        // File size
        NSNumber *fileSize = file[@"size"] ?: @0;
        [sizes addObject:fileSize];

        // File URL
        NSString *fileURL = file[@"url"] ?: @"";
        [urls addObject:fileURL];

        // Hash
        NSDictionary *hashesMap = file[@"hashes"];
        NSString *sha1 = hashesMap[@"sha1"] ?: @"";
        [hashes addObject:sha1];
    }];

    item[@"versionNames"]      = names ?: @[];
    item[@"mcVersionNames"]    = mcNames;
    item[@"versionSizes"]      = sizes;
    item[@"versionUrls"]       = urls;
    item[@"versionHashes"]     = hashes;
    item[@"versionDetailsLoaded"] = @(YES);
}

// Submit download tasks (from .mrpack) to the provided MinecraftResourceDownloadTask
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

    // Extract modrinth.index.json
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

    // Start queueing downloads
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

        // Create the download task
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:url
                                                                  size:size
                                                                   sha:sha
                                                               altName:nil
                                                                toPath:path];
        if (task) {
            [downloader.fileList addObject:indexFile[@"path"] ?: @""];
            [task resume];
        } else if (!downloader.progress.cancelled) {
            // If for some reason the task couldn't be created, but wasn't cancelled,
            // mark progress so we don't get stuck
            downloader.progress.completedUnitCount++;
        } else {
            return; // If cancelled, just stop
        }
    }

    // Extract overrides (if present)
    [ModpackUtils archive:archive extractDirectory:@"overrides" toPath:destPath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:
           [NSString stringWithFormat:@"Failed to extract overrides from modpack package: %@", error.localizedDescription]];
        return;
    }
    // Extract client-overrides (if present)
    [ModpackUtils archive:archive extractDirectory:@"client-overrides" toPath:destPath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:
           [NSString stringWithFormat:@"Failed to extract client-overrides from modpack package: %@", error.localizedDescription]];
        return;
    }

    // Delete the original .mrpack
    [[NSFileManager defaultManager] removeItemAtPath:packagePath error:nil];

    // Download dependency client json (if available)
    NSDictionary<NSString *, NSString *> *depInfo = [ModpackUtils infoForDependencies:indexDict[@"dependencies"]];
    if (depInfo[@"json"]) {
        NSString *jsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json",
                              getenv("POJAV_GAME_DIR"), depInfo[@"id"]];
        NSURLSessionDownloadTask *depTask =
          [downloader createDownloadTask:depInfo[@"json"] size:0 sha:nil altName:nil toPath:jsonPath];
        [depTask resume];
    }
    // TODO: Additional automation for Forge if needed

    // Create or update the profile in PLProfiles
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
        // Optionally select the profile
        PLProfiles.current.selectedProfileName = indexDict[@"name"];
    }
}

@end
