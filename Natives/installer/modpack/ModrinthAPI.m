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

    // Ensure required keys exist in searchFilters to prevent runtime errors
    if (!searchFilters[@"isModpack"]) {
        NSLog(@"[ModrinthAPI] Error: 'isModpack' key is missing in searchFilters.");
        return nil;
    }

    // Construct facet string for filtering
    NSMutableString *facetString = [NSMutableString stringWithString:@"["];
    [facetString appendFormat:@"[\"project_type:%@\"]", ([searchFilters[@"isModpack"] boolValue] ? @"modpack" : @"mod")];
    
    if (searchFilters[@"mcVersion"] && [searchFilters[@"mcVersion"] length] > 0) {
        [facetString appendFormat:@",[\"versions:%@\"]", searchFilters[@"mcVersion"]];
    }
    [facetString appendString:@"]"];

    // Properly encode the query string to handle special characters
    NSString *query = searchFilters[@"name"] ? searchFilters[@"name"] : @"";
    NSString *encodedQuery = [query stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];

    NSDictionary *params = @{
        @"facets": facetString,
        @"query": encodedQuery,
        @"limit": @(limit),
        @"index": @"relevance",
        @"offset": @(modrinthSearchResult.count)
    };

    NSLog(@"[ModrinthAPI] Initiating search with parameters: %@", params);

    // Perform API request
    NSDictionary *response = [self getEndpoint:@"search" params:params];
    if (!response) {
        NSLog(@"[ModrinthAPI] Failed to receive search response.");
        return nil;
    }

    NSLog(@"[ModrinthAPI] Search response received with %lu hits.", (unsigned long)[response[@"hits"] count]);

    // Process response and build result array
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

    // Update pagination status
    self.reachedLastPage = (result.count >= [response[@"total_hits"] unsignedIntegerValue]);
    return result;
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    NSString *endpoint = [NSString stringWithFormat:@"project/%@/version", item[@"id"]];
    NSLog(@"[ModrinthAPI] Loading details for mod ID: %@", item[@"id"]);

    // Fetch version details
    NSArray *response = [self getEndpoint:endpoint params:nil];
    if (!response) {
        NSLog(@"[ModrinthAPI] Failed to load version details for mod ID: %@", item[@"id"]);
        return;
    }

    NSLog(@"[ModrinthAPI] Successfully received version details for mod ID: %@", item[@"id"]);

    // Initialize arrays for storing version details
    NSMutableArray *names = [NSMutableArray array];
    NSMutableArray *mcNames = [NSMutableArray array];
    NSMutableArray *urls = [NSMutableArray array];
    NSMutableArray *hashes = [NSMutableArray array];
    NSMutableArray *sizes = [NSMutableArray array];

    // Extract details with safety checks
    for (NSDictionary *version in response) {
        if (![version isKindOfClass:[NSDictionary class]]) {
            NSLog(@"[ModrinthAPI] Skipping invalid version entry for mod ID: %@", item[@"id"]);
            continue;
        }

        NSString *name = version[@"name"] ?: @"";
        [names addObject:name];

        NSArray *gameVersions = version[@"game_versions"];
        NSString *mcVersion = (gameVersions && [gameVersions count] > 0) ? gameVersions[0] : @"";
        [mcNames addObject:mcVersion];

        NSArray *files = version[@"files"];
        NSDictionary *file = [files firstObject];
        if (file) {
            NSString *url = file[@"url"] ?: @"";
            [urls addObject:url];

            NSDictionary *hashesMap = file[@"hashes"];
            NSString *sha1 = hashesMap ? hashesMap[@"sha1"] : @"";
            [hashes addObject:sha1 ?: @""];

            NSNumber *size = file[@"size"] ?: @0;
            [sizes addObject:size];
        } else {
            NSLog(@"[ModrinthAPI] No files found for version: %@ of mod ID: %@", name, item[@"id"]);
            [urls addObject:@""];
            [hashes addObject:@""];
            [sizes addObject:@0];
        }
    }

    // Store extracted details in the item dictionary
    item[@"versionNames"] = names;
    item[@"mcVersionNames"] = mcNames;
    item[@"versionSizes"] = sizes;
    item[@"versionUrls"] = urls;
    item[@"versionHashes"] = hashes;
    item[@"versionDetailsLoaded"] = @(YES);

    NSLog(@"[ModrinthAPI] Completed loading details for mod ID: %@", item[@"id"]);
}

- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath {
    NSError *error = nil;

    // Open the modpack archive
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
    if (error) {
        NSLog(@"[ModrinthAPI] Failed to open modpack package at %@: %@", packagePath, error.localizedDescription);
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to open modpack package: %@", error.localizedDescription]];
        return;
    }
    NSLog(@"[ModrinthAPI] Successfully opened modpack package: %@", packagePath);

    // Extract and parse the index file
    NSData *indexData = [archive extractDataFromFile:@"modrinth.index.json" error:&error];
    if (error) {
        NSLog(@"[ModrinthAPI] Failed to extract modrinth.index.json: %@", error.localizedDescription);
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract modrinth.index.json: %@", error.localizedDescription]];
        return;
    }

    NSDictionary *indexDict = [NSJSONSerialization JSONObjectWithData:indexData options:0 error:&error];
    if (error) {
        NSLog(@"[ModrinthAPI] Failed to parse modrinth.index.json: %@", error.localizedDescription);
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to parse modrinth.index.json: %@", error.localizedDescription]];
        return;
    }
    NSLog(@"[ModrinthAPI] Successfully parsed modrinth.index.json");

    // Process files from the index
    NSArray *filesArray = indexDict[@"files"];
    if (![filesArray isKindOfClass:[NSArray class]]) {
        NSLog(@"[ModrinthAPI] Invalid or missing 'files' array in modrinth.index.json");
        [downloader finishDownloadWithErrorString:@"Invalid or missing 'files' array in index"];
        return;
    }

    NSMutableSet *processedFiles = [NSMutableSet new];
    downloader.progress.totalUnitCount = 0;

    for (NSDictionary *indexFile in filesArray) {
        if (![indexFile isKindOfClass:[NSDictionary class]]) {
            NSLog(@"[ModrinthAPI] Skipping invalid file entry in index");
            continue;
        }

        NSString *filePath = indexFile[@"path"];
        if (!filePath || [filePath length] == 0) {
            NSLog(@"[ModrinthAPI] Skipping file with empty path");
            continue;
        }

        if ([processedFiles containsObject:filePath]) {
            NSLog(@"[ModrinthAPI] Skipping duplicate file: %@", filePath);
            continue;
        }

        [processedFiles addObject:filePath];
        downloader.progress.totalUnitCount++;

        NSArray *downloads = indexFile[@"downloads"];
        NSString *url = [downloads firstObject];
        if (!url) {
            NSLog(@"[ModrinthAPI] Skipping file with no download URL: %@", filePath);
            continue;
        }

        NSDictionary *hashes = indexFile[@"hashes"];
        NSString *sha = hashes ? hashes[@"sha1"] : nil;
        NSString *path = [destPath stringByAppendingPathComponent:filePath];
        NSUInteger size = [indexFile[@"fileSize"] unsignedIntegerValue];

        NSLog(@"[ModrinthAPI] Scheduling download for file: %@", filePath);

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
            NSLog(@"[ModrinthAPI] Download cancelled, stopping task submission");
            return;
        }
    }

    // Extract overrides
    NSLog(@"[ModrinthAPI] Extracting 'overrides' directory...");
    [ModpackUtils archive:archive extractDirectory:@"overrides" toPath:destPath error:&error];
    if (error) {
        NSLog(@"[ModrinthAPI] Failed to extract overrides: %@", error.localizedDescription);
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract overrides: %@", error.localizedDescription]];
        return;
    }

    // Extract client-overrides
    NSLog(@"[ModrinthAPI] Extracting 'client-overrides' directory...");
    [ModpackUtils archive:archive extractDirectory:@"client-overrides" toPath:destPath error:&error];
    if (error) {
        NSLog(@"[ModrinthAPI] Failed to extract client-overrides: %@", error.localizedDescription);
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract client-overrides: %@", error.localizedDescription]];
        return;
    }

    // Clean up temporary package file
    NSLog(@"[ModrinthAPI] Removing temporary package file: %@", packagePath);
    [[NSFileManager defaultManager] removeItemAtPath:packagePath error:nil];

    // Handle dependencies
    NSDictionary<NSString *, NSString *> *depInfo = [ModpackUtils infoForDependencies:indexDict[@"dependencies"]];
    if (depInfo[@"json"]) {
        NSString *jsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), depInfo[@"id"]];
        NSLog(@"[ModrinthAPI] Scheduling dependency JSON download to: %@", jsonPath);
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:depInfo[@"json"] size:0 sha:nil altName:nil toPath:jsonPath];
        [task resume];
    }

    // Set profile information
    NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
    NSDictionary *profileInfo = @{
        @"gameDir": [NSString stringWithFormat:@"./custom_gamedir/%@", destPath.lastPathComponent],
        @"name": indexDict[@"name"] ?: @"",
        @"lastVersionId": depInfo[@"id"] ?: @"",
        @"icon": [NSString stringWithFormat:@"data:image/png;base64,%@",
                  [[NSData dataWithContentsOfFile:tmpIconPath] base64EncodedStringWithOptions:0]]
    };
    NSLog(@"[ModrinthAPI] Setting profile information: %@", profileInfo);
    PLProfiles.current.profiles[indexDict[@"name"]] = profileInfo;

    NSLog(@"[ModrinthAPI] Download task submission completed for package: %@", packagePath);
}

@end
