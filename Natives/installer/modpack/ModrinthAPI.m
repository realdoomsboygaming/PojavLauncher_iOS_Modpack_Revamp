#import "MinecraftResourceDownloadTask.h"
#import "ModrinthAPI.h"
#import "PLProfiles.h"
#import "ModpackUtils.h"
#import "AFNetworking.h"

@implementation ModrinthAPI

- (instancetype)initWithURL:(NSString *)url {
    self = [super initWithURL:url];
    if (self) {
        self.reachedLastPage = NO;
        NSLog(@"ModrinthAPI: Initialized with base URL: %@", url);
    }
    return self;
}

- (instancetype)init {
    return [self initWithURL:@"https://api.modrinth.com/v2"];
}

- (NSMutableArray *)searchModWithFilters:(NSDictionary *)searchFilters previousPageResult:(NSMutableArray *)prevResult {
    int limit = 50;

    NSMutableString *facetString = [NSMutableString stringWithString:@"["];
    [facetString appendFormat:@"[\"project_type:%@\"]", ([searchFilters[@"isModpack"] boolValue] ? @"modpack" : @"mod")];
    if (searchFilters[@"mcVersion"] && [searchFilters[@"mcVersion"] length] > 0) {
        [facetString appendFormat:@",[\"versions:%@\"]", searchFilters[@"mcVersion"]];
    }
    [facetString appendString:@"]"];

    NSDictionary *params = @{
        @"facets": facetString,
        @"query": (searchFilters[@"name"] ? [searchFilters[@"name"] stringByReplacingOccurrencesOfString:@" " withString:@"+"] : @""),
        @"limit": @(limit),
        @"index": @"relevance",
        @"offset": @(prevResult.count)
    };
    NSLog(@"searchModWithFilters: Searching with params: %@", params);

    NSDictionary *response = [self getEndpoint:@"search" params:params];
    if (!response) {
        NSLog(@"searchModWithFilters: Failed to get response: %@", self.lastError);
        return nil;
    }

    NSMutableArray *result = prevResult ?: [NSMutableArray new];
    NSArray *hits = response[@"hits"];
    if (![hits isKindOfClass:[NSArray class]]) {
        NSLog(@"searchModWithFilters: Invalid response format, 'hits' is not an array: %@", hits);
        self.lastError = [NSError errorWithDomain:@"ModrinthAPIErrorDomain"
                                            code:-1
                                        userInfo:@{NSLocalizedDescriptionKey: @"Invalid response format from search endpoint"}];
        return nil;
    }

    for (NSDictionary *hit in hits) {
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
        NSLog(@"searchModWithFilters: Added mod %@ (ID: %@)", entry[@"title"], entry[@"id"]);
    }
    self.reachedLastPage = (result.count >= [response[@"total_hits"] unsignedIntegerValue]);
    NSLog(@"searchModWithFilters: Total hits: %lu, reached last page: %d", (unsigned long)[response[@"total_hits"] unsignedIntegerValue], self.reachedLastPage);
    return result;
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    NSString *endpoint = [NSString stringWithFormat:@"project/%@/version", item[@"id"]];
    NSLog(@"loadDetailsOfMod: Loading details for mod ID: %@", item[@"id"]);

    id response = [self getEndpoint:endpoint params:nil];
    if (!response) {
        NSLog(@"loadDetailsOfMod: Failed to load details: %@", self.lastError);
        return;
    }

    if (![response isKindOfClass:[NSArray class]]) {
        NSLog(@"loadDetailsOfMod: Invalid response format, expected array: %@", response);
        self.lastError = [NSError errorWithDomain:@"ModrinthAPIErrorDomain"
                                            code:-2
                                        userInfo:@{NSLocalizedDescriptionKey: @"Invalid response format from version endpoint"}];
        return;
    }

    NSArray *versions = (NSArray *)response;
    NSArray *names = [versions valueForKey:@"name"];
    NSMutableArray *mcNames = [NSMutableArray arrayWithCapacity:versions.count];
    NSMutableArray *urls = [NSMutableArray arrayWithCapacity:versions.count];
    NSMutableArray *hashes = [NSMutableArray arrayWithCapacity:versions.count];
    NSMutableArray *sizes = [NSMutableArray arrayWithCapacity:versions.count];

    [versions enumerateObjectsUsingBlock:^(NSDictionary *version, NSUInteger i, BOOL *stop) {
        NSDictionary *file = [version[@"files"] firstObject];
        NSString *gameVersion = (version[@"game_versions"] && [version[@"game_versions"] count] > 0) ? version[@"game_versions"][0] : @"";
        [mcNames addObject:gameVersion];
        [sizes addObject:file[@"size"] ?: @0];
        [urls addObject:file[@"url"] ?: @""];
        NSDictionary *hashesMap = file[@"hashes"];
        [hashes addObject:hashesMap[@"sha1"] ?: @""];
    }];

    item[@"versionNames"] = names;
    item[@"mcVersionNames"] = mcNames;
    item[@"versionSizes"] = sizes;
    item[@"versionUrls"] = urls;
    item[@"versionHashes"] = hashes;
    item[@"versionDetailsLoaded"] = @(YES);
    NSLog(@"loadDetailsOfMod: Loaded %lu versions for mod ID: %@", (unsigned long)names.count, item[@"id"]);
}

- (void)installModpackFromDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion {
    NSArray *versionUrls = modDetail[@"versionUrls"];
    NSArray *versionNames = modDetail[@"versionNames"];

    if (selectedVersion >= versionUrls.count || selectedVersion >= versionNames.count) {
        NSLog(@"installModpackFromDetail: Invalid index %lu (URLs: %lu, Names: %lu)",
              (unsigned long)selectedVersion, (unsigned long)versionUrls.count, (unsigned long)versionNames.count);
        self.lastError = [NSError errorWithDomain:@"ModrinthAPIErrorDomain"
                                            code:100
                                        userInfo:@{NSLocalizedDescriptionKey: @"Selected version index is out of bounds."}];
        return;
    }

    NSString *downloadUrl = versionUrls[selectedVersion];
    NSString *versionName = versionNames[selectedVersion];
    NSLog(@"installModpackFromDetail: Installing modpack %@ at version %@ (URL: %@)",
          modDetail[@"title"], versionName, downloadUrl);

    NSDictionary *userInfo = @{
        @"detail": modDetail,
        @"index": @(selectedVersion),
        @"url": downloadUrl
    };
    [[NSNotificationCenter defaultCenter] postNotificationName:@"InstallModpack"
                                                        object:self
                                                      userInfo:userInfo];
}

- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath {
    NSError *error = nil;
    NSLog(@"downloader: Opening archive at %@", packagePath);
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
    if (error) {
        NSLog(@"downloader: Failed to open package: %@", error);
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to open modpack package: %@", error.localizedDescription]];
        return;
    }

    NSLog(@"downloader: Extracting modrinth.index.json");
    NSData *indexData = [archive extractDataFromFile:@"modrinth.index.json" error:&error];
    if (!indexData || error) {
        NSLog(@"downloader: Failed to extract modrinth.index.json: %@", error);
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract modrinth.index.json: %@", error.localizedDescription]];
        return;
    }

    NSDictionary *indexDict = [NSJSONSerialization JSONObjectWithData:indexData options:0 error:&error];
    if (!indexDict || error) {
        NSLog(@"downloader: Failed to parse modrinth.index.json: %@", error);
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to parse modrinth.index.json: %@", error.localizedDescription]];
        return;
    }
    NSLog(@"downloader: Successfully parsed modrinth.index.json");

    NSArray *filesArray = indexDict[@"files"];
    if (![filesArray isKindOfClass:[NSArray class]]) {
        NSLog(@"downloader: Invalid 'files' format in index: %@", filesArray);
        [downloader finishDownloadWithErrorString:@"Invalid modrinth.index.json: 'files' is not an array"];
        return;
    }

    NSMutableSet *processedFiles = [NSMutableSet new];
    downloader.progress.totalUnitCount = 0;

    for (NSDictionary *indexFile in filesArray) {
        NSString *filePath = indexFile[@"path"] ?: @"";
        if (filePath.length == 0) {
            NSLog(@"downloader: Skipping file with empty path");
            continue;
        }

        if ([processedFiles containsObject:filePath]) {
            NSLog(@"downloader: Skipping duplicate file: %@", filePath);
            continue;
        }

        [processedFiles addObject:filePath];
        downloader.progress.totalUnitCount++;
        NSLog(@"downloader: Processing file: %@ (Total count: %lld)", filePath, downloader.progress.totalUnitCount);

        NSArray *downloads = indexFile[@"downloads"];
        NSString *url = [downloads firstObject] ?: @"";
        if (url.length == 0 || ![downloads isKindOfClass:[NSArray class]]) {
            NSLog(@"downloader: Skipping file %@ with no valid download URL", filePath);
            downloader.progress.completedUnitCount++;
            continue;
        }

        NSString *sha = indexFile[@"hashes"][@"sha1"] ?: @"";
        NSString *path = [destPath stringByAppendingPathComponent:filePath];
        NSUInteger size = [indexFile[@"fileSize"] unsignedLongLongValue];
        if (size == 0) size = 1;

        NSString *dirPath = [path stringByDeletingLastPathComponent];
        if (![[NSFileManager defaultManager] fileExistsAtPath:dirPath]) {
            [[NSFileManager defaultManager] createDirectoryAtPath:dirPath withIntermediateDirectories:YES attributes:nil error:&error];
            if (error) {
                NSLog(@"downloader: Failed to create directory %@: %@", dirPath, error);
                error = nil; // Reset error but proceed
            } else {
                NSLog(@"downloader: Created directory %@", dirPath);
            }
        }

        NSURLSessionDownloadTask *task = [downloader createDownloadTask:url size:size sha:sha altName:nil toPath:path success:^{
            NSLog(@"downloader: Download completed for %@", path);
        }];
        if (task) {
            @synchronized(downloader.fileList) {
                if (!downloader.fileList) {
                    downloader.fileList = [NSMutableArray new];
                    NSLog(@"downloader: Initialized fileList for downloader");
                }
                if (![downloader.fileList containsObject:filePath]) {
                    [downloader.fileList addObject:filePath];
                }
            }
            NSLog(@"downloader: Starting download for %@", path);
            [task resume];
        } else if (!downloader.progress.cancelled) {
            NSLog(@"downloader: Failed to create task for %@", path);
            downloader.progress.completedUnitCount++;
        } else {
            NSLog(@"downloader: Download cancelled");
            return;
        }
    }

    NSLog(@"downloader: Extracting overrides");
    [ModpackUtils archive:archive extractDirectory:@"overrides" toPath:destPath error:&error];
    if (error) {
        NSLog(@"downloader: Failed to extract overrides: %@", error);
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract overrides: %@", error.localizedDescription]];
        return;
    }

    NSLog(@"downloader: Extracting client-overrides");
    [ModpackUtils archive:archive extractDirectory:@"client-overrides" toPath:destPath error:&error];
    if (error) {
        NSLog(@"downloader: Failed to extract client-overrides: %@", error);
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract client-overrides: %@", error.localizedDescription]];
        return;
    }

    NSError *removeError = nil;
    [[NSFileManager defaultManager] removeItemAtPath:packagePath error:&removeError];
    if (removeError) {
        NSLog(@"downloader: Failed to remove package file %@: %@", packagePath, removeError);
    } else {
        NSLog(@"downloader: Removed package file %@", packagePath);
    }

    NSDictionary<NSString *, NSString *> *depInfo = [ModpackUtils infoForDependencies:indexDict[@"dependencies"]];
    if (depInfo[@"json"] && depInfo[@"id"]) {
        NSString *jsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), depInfo[@"id"]];
        NSLog(@"downloader: Downloading dependency JSON to %@", jsonPath);
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:depInfo[@"json"] size:0 sha:nil altName:nil toPath:jsonPath success:^{
            NSLog(@"downloader: Dependency JSON downloaded to %@", jsonPath);
        }];
        if (task) {
            [task resume];
        } else {
            NSLog(@"downloader: Failed to create dependency download task");
        }
    }

    NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
    NSData *iconData = [archive extractDataFromFile:@"icon.png" error:&error];
    if (iconData && !error) {
        [iconData writeToFile:tmpIconPath atomically:YES];
        NSLog(@"downloader: Extracted icon to %@", tmpIconPath);
    } else {
        NSLog(@"downloader: No icon found or extraction failed: %@", error);
    }

    NSString *profileName = indexDict[@"name"] ?: @"Unknown Modpack";
    NSDictionary *profileInfo = @{
        @"gameDir": [NSString stringWithFormat:@"./custom_gamedir/%@", destPath.lastPathComponent],
        @"name": profileName,
        @"lastVersionId": depInfo[@"id"] ?: @"",
        @"icon": iconData ? [NSString stringWithFormat:@"data:image/png;base64,%@", [iconData base64EncodedStringWithOptions:0]] : @""
    };
    NSLog(@"downloader: Creating profile: %@", profileName);
    PLProfiles.current.profiles[profileName] = [profileInfo mutableCopy];
    PLProfiles.current.selectedProfileName = profileName;
    [PLProfiles.current save];

    NSLog(@"downloader: Finalizing downloads");
    [downloader finalizeDownloads];
    NSLog(@"downloader: Modpack installation completed");
}

@end
