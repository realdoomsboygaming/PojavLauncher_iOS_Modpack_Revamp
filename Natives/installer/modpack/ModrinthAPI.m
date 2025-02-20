#import "MinecraftResourceDownloadTask.h"
#import "ModrinthAPI.h"
#import "PLProfiles.h"
#import "UZKArchive.h"
#import "ModpackUtils.h"

@implementation ModrinthAPI

#pragma mark - Init

- (instancetype)init {
    // Calls super’s designated initializer with Modrinth’s base URL
    return [super initWithURL:@"https://api.modrinth.com/v2"];
}

#pragma mark - Search

- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, NSString *> *)searchFilters
                       previousPageResult:(NSMutableArray *)modrinthSearchResult
{
    int limit = 50;

    // Build facets for project type & optional Minecraft version
    NSMutableString *facetString = [NSMutableString stringWithString:@"["];
    [facetString appendFormat:@"[\"project_type:%@\"]", (searchFilters[@"isModpack"].boolValue ? @"modpack" : @"mod")];
    if (searchFilters[@"mcVersion"].length > 0) {
        [facetString appendFormat:@",[\"versions:%@\"]", searchFilters[@"mcVersion"]];
    }
    [facetString appendString:@"]"];

    NSDictionary *params = @{
        @"facets": facetString,
        @"query": [searchFilters[@"name"] ?: @"" stringByReplacingOccurrencesOfString:@" " withString:@"+"],
        @"limit": @(limit),
        @"index": @"relevance",
        @"offset": @(modrinthSearchResult.count ?: 0)
    };

    NSDictionary *response = [self getEndpoint:@"search" params:params];
    if (!response) {
        // self.lastError should have the underlying error
        return nil;
    }

    NSMutableArray *result = modrinthSearchResult ?: [NSMutableArray new];
    NSArray *hits = response[@"hits"];
    if (![hits isKindOfClass:[NSArray class]]) {
        // Something unexpected in the JSON
        return result;
    }

    for (NSDictionary *hit in hits) {
        BOOL isModpack = [hit[@"project_type"] isEqualToString:@"modpack"];
        [result addObject:@{
            @"apiSource": @(1),  // 1 => “Modrinth”
            @"isModpack": @(isModpack),
            @"id": hit[@"project_id"] ?: @"",
            @"title": hit[@"title"] ?: @"",
            @"description": hit[@"description"] ?: @"",
            @"imageUrl": hit[@"icon_url"] ?: @""
        }.mutableCopy];
    }

    // total_hits => if we've displayed them all, we reached the last page
    NSUInteger totalHits = [response[@"total_hits"] unsignedLongValue];
    self.reachedLastPage = (result.count >= totalHits);

    return result;
}

#pragma mark - Load Details

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    // Must have an ID
    if (!item[@"id"]) return;

    // Endpoint: e.g. "project/XXXX/version"
    NSString *endpoint = [NSString stringWithFormat:@"project/%@/version", item[@"id"]];
    NSArray *response = [self getEndpoint:endpoint params:nil];
    if (![response isKindOfClass:[NSArray class]]) {
        return; // Could be nil or an error
    }

    // We’ll build arrays of exactly the same length, so each index lines up
    NSMutableArray<NSString *> *names   = [NSMutableArray array];
    NSMutableArray<NSString *> *mcNames = [NSMutableArray array];
    NSMutableArray<NSString *> *urls    = [NSMutableArray array];
    NSMutableArray<NSString *> *hashes  = [NSMutableArray array];
    NSMutableArray<NSNumber *> *sizes   = [NSMutableArray array];

    for (NSDictionary *versionDict in response) {
        if (![versionDict isKindOfClass:[NSDictionary class]]) {
            continue;
        }

        // "name" => the user-friendly label for this version
        NSString *versionName = versionDict[@"name"] ?: @"Unnamed Version";
        [names addObject:versionName];

        // Extract a game version, if present
        NSArray *gameVers = ([versionDict[@"game_versions"] isKindOfClass:[NSArray class]]
                             ? versionDict[@"game_versions"]
                             : @[]);
        NSString *mcVersion = (gameVers.count > 0 ? gameVers.firstObject : @"");
        [mcNames addObject:mcVersion];

        // The "files" array can hold multiple files, but typically there's at least one
        NSDictionary *file = [[versionDict objectForKey:@"files"] firstObject];
        if ([file isKindOfClass:[NSDictionary class]]) {
            // File URL
            NSString *fileURL = file[@"url"] ?: @"";
            [urls addObject:fileURL];

            // File size
            NSNumber *fileSize = file[@"size"] ?: @0;
            [sizes addObject:fileSize];

            // Hash
            NSDictionary *hashesMap = file[@"hashes"];
            NSString *sha1Hash = [hashesMap[@"sha1"] isKindOfClass:[NSString class]] ? hashesMap[@"sha1"] : @"";
            [hashes addObject:sha1Hash];
        } else {
            // No valid file => add placeholders so arrays stay aligned
            [urls addObject:@""];
            [sizes addObject:@0];
            [hashes addObject:@""];
        }
    }

    // Attach them to our item dictionary so the UI can show them in the action sheet
    item[@"versionNames"]         = names;
    item[@"mcVersionNames"]       = mcNames;
    item[@"versionUrls"]          = urls;
    item[@"versionSizes"]         = sizes;
    item[@"versionHashes"]        = hashes;
    item[@"versionDetailsLoaded"] = @(YES);
}

#pragma mark - Install Steps

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
    if (!indexData || error) {
        [downloader finishDownloadWithErrorString:
            [NSString stringWithFormat:@"Failed to read modrinth.index.json: %@", error.localizedDescription]];
        return;
    }

    NSDictionary *indexDict = [NSJSONSerialization JSONObjectWithData:indexData
                                                              options:0
                                                                error:&error];
    if (!indexDict || error) {
        [downloader finishDownloadWithErrorString:
            [NSString stringWithFormat:@"Failed to parse modrinth.index.json: %@", error.localizedDescription]];
        return;
    }

    // Queue each file for download
    NSArray *files = indexDict[@"files"];
    if (![files isKindOfClass:[NSArray class]]) {
        [downloader finishDownloadWithErrorString:@"The modrinth.index.json has no valid 'files' array."];
        return;
    }

    downloader.progress.totalUnitCount = files.count;

    for (NSDictionary *indexFile in files) {
        NSArray *dlList = indexFile[@"downloads"];
        NSString *url    = ([dlList isKindOfClass:[NSArray class]] ? [dlList firstObject] : @"") ?: @"";
        NSString *sha    = indexFile[@"hashes"][@"sha1"] ?: @"";
        NSString *subPath = indexFile[@"path"] ?: @"";

        NSUInteger size = [indexFile[@"fileSize"] unsignedLongLongValue];
        NSString *finalPath = [destPath stringByAppendingPathComponent:subPath];

        // Create the download task
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:url
                                                                  size:size
                                                                   sha:sha
                                                               altName:nil
                                                                toPath:finalPath];
        if (task) {
            [downloader.fileList addObject:subPath];
            [task resume];
        } else if (!downloader.progress.cancelled) {
            // If it failed to create the task but wasn't cancelled,
            // let's manually increment the progress so we don't hang
            downloader.progress.completedUnitCount++;
        } else {
            // If cancelled, stop immediately
            return;
        }
    }

    // Extract overrides
    [ModpackUtils archive:archive extractDirectory:@"overrides" toPath:destPath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:
            [NSString stringWithFormat:@"Failed to extract 'overrides': %@", error.localizedDescription]];
        return;
    }

    // Extract client-overrides
    [ModpackUtils archive:archive extractDirectory:@"client-overrides" toPath:destPath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:
            [NSString stringWithFormat:@"Failed to extract 'client-overrides': %@", error.localizedDescription]];
        return;
    }

    // Remove the .mrpack once extracted
    [[NSFileManager defaultManager] removeItemAtPath:packagePath error:nil];

    // Dependencies (e.g., for Fabric/Quilt)
    NSDictionary<NSString *, NSString *> *depInfo = [ModpackUtils infoForDependencies:indexDict[@"dependencies"]];
    if (depInfo[@"json"]) {
        NSString *jsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json",
                              getenv("POJAV_GAME_DIR"), depInfo[@"id"]];
        NSURLSessionDownloadTask *depTask = [downloader createDownloadTask:depInfo[@"json"]
                                                                     size:0
                                                                      sha:nil
                                                                  altName:nil
                                                                   toPath:jsonPath];
        [depTask resume];
    }

    // Create or update the profile
    NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
    NSData   *iconData    = [NSData dataWithContentsOfFile:tmpIconPath];
    NSString *base64Icon  = iconData ? [iconData base64EncodedStringWithOptions:0] : @"";

    NSString *packName = [indexDict[@"name"] isKindOfClass:[NSString class]]
                         ? indexDict[@"name"]
                         : @"Unnamed Pack";
    PLProfiles.current.profiles[packName] = [@{
        @"gameDir": [NSString stringWithFormat:@"./custom_gamedir/%@", destPath.lastPathComponent],
        @"name": packName,
        @"lastVersionId": depInfo[@"id"] ?: @"",
        @"icon": [NSString stringWithFormat:@"data:image/png;base64,%@", base64Icon]
    } mutableCopy];

    // Optionally select the new profile
    PLProfiles.current.selectedProfileName = packName;
}

@end
