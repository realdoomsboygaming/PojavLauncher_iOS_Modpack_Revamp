#import "MinecraftResourceDownloadTask.h"
#import "ModrinthAPI.h"
#import "PLProfiles.h"
#import "ModloaderInstaller.h"

@implementation ModrinthAPI

- (instancetype)init {
    return [super initWithURL:@"https://api.modrinth.com/v2"];
}

- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, NSString *> *)searchFilters previousPageResult:(NSMutableArray *)modrinthSearchResult {
    int limit = 50;

    NSMutableString *facetString = [NSMutableString new];
    [facetString appendString:@"["];
    [facetString appendFormat:@"[\"project_type:%@\"]", searchFilters[@"isModpack"].boolValue ? @"modpack" : @"mod"];
    if (searchFilters[@"mcVersion"].length > 0) {
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
        [result addObject:@{
            @"apiSource": @(1), // Constant MODRINTH
            @"isModpack": @(isModpack),
            @"id": hit[@"project_id"],
            @"title": hit[@"title"],
            @"description": hit[@"description"],
            @"imageUrl": hit[@"icon_url"]
        }.mutableCopy];
    }
    self.reachedLastPage = result.count >= [response[@"total_hits"] unsignedLongValue];
    return result;
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    NSArray *response = [self getEndpoint:[NSString stringWithFormat:@"project/%@/version", item[@"id"]] params:nil];
    if (!response) {
        return;
    }
    NSArray<NSString *> *names = [response valueForKey:@"name"];
    NSMutableArray<NSString *> *mcNames = [NSMutableArray new];
    NSMutableArray<NSString *> *urls = [NSMutableArray new];
    NSMutableArray<NSString *> *hashes = [NSMutableArray new];
    NSMutableArray<NSString *> *sizes = [NSMutableArray new];
    [response enumerateObjectsUsingBlock:
     ^(NSDictionary *version, NSUInteger i, BOOL *stop) {
         NSDictionary *file = [version[@"files"] firstObject];
         mcNames[i] = [version[@"game_versions"] firstObject];
         sizes[i] = file[@"size"];
         urls[i] = file[@"url"];
         NSDictionary *hashesMap = file[@"hashes"];
         hashes[i] = hashesMap[@"sha1"] ?: [NSNull null];
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
    NSDictionary* indexDict = [NSJSONSerialization JSONObjectWithData:indexData options:kNilOptions error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to parse modrinth.index.json: %@", error.localizedDescription]];
        return;
    }

    downloader.progress.totalUnitCount = [indexDict[@"files"] count];
    for (NSDictionary *indexFile in indexDict[@"files"]) {
        // Here we fix the URL extraction: if downloads is an array use firstObject; if a dictionary, use the "primary" key.
        id downloads = indexFile[@"downloads"];
        NSString *url = @"";
        if ([downloads isKindOfClass:[NSArray class]]) {
            url = [downloads firstObject];
        } else if ([downloads isKindOfClass:[NSDictionary class]]) {
            url = downloads[@"primary"];
        }
        NSString *sha = indexFile[@"hashes"][@"sha1"];
        NSString *path = [destPath stringByAppendingPathComponent:indexFile[@"path"]];
        NSUInteger size = [indexFile[@"fileSize"] unsignedLongLongValue];
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:url size:size sha:sha altName:nil toPath:path];
        if (task) {
            [downloader.fileList addObject:indexFile[@"path"]];
            [task resume];
        } else if (!downloader.progress.cancelled) {
            downloader.progress.completedUnitCount++;
        } else {
            return; // cancelled
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

    // Delete package cache
    [NSFileManager.defaultManager removeItemAtPath:packagePath error:nil];

    // Download dependency client json (if available)
    NSDictionary<NSString *, NSString *> *depInfo = [ModpackUtils infoForDependencies:indexDict[@"dependencies"]];
    if (depInfo[@"json"]) {
        NSString *jsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), depInfo[@"id"]];
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:depInfo[@"json"] size:0 sha:nil altName:nil toPath:jsonPath];
        [task resume];
    }
    
    // Create profile as before
    NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
    PLProfiles.current.profiles[indexDict[@"name"]] = @{
        @"gameDir": [NSString stringWithFormat:@"./custom_gamedir/%@", destPath.lastPathComponent],
        @"name": indexDict[@"name"],
        @"lastVersionId": depInfo[@"id"],
        @"icon": [NSString stringWithFormat:@"data:image/png;base64,%@",
                   [[NSData dataWithContentsOfFile:tmpIconPath]
                    base64EncodedStringWithOptions:0]]
    }.mutableCopy;
    PLProfiles.current.selectedProfileName = indexDict[@"name"];

    // Write the mod loader installer file
    // Determine loader info from manifest:
    NSDictionary *minecraft = indexDict[@"minecraft"];
    NSString *vanillaVersion = @"";
    NSString *modLoaderId = @"";
    NSString *modLoaderVersion = @"";
    if (minecraft && [minecraft isKindOfClass:[NSDictionary class]]) {
        vanillaVersion = minecraft[@"version"] ?: @"";
        NSArray *modLoaders = minecraft[@"modLoaders"];
        NSDictionary *primaryModLoader = nil;
        if ([modLoaders isKindOfClass:[NSArray class]] && modLoaders.count > 0) {
            for (NSDictionary *loader in modLoaders) {
                if ([loader[@"primary"] boolValue]) {
                    primaryModLoader = loader;
                    break;
                }
            }
            if (!primaryModLoader) { primaryModLoader = modLoaders[0]; }
            NSString *rawId = primaryModLoader[@"id"] ?: @"";
            NSRange dashRange = [rawId rangeOfString:@"-"];
            if (dashRange.location != NSNotFound) {
                NSString *loaderName = [rawId substringToIndex:dashRange.location];
                NSString *loaderVer = [rawId substringFromIndex:(dashRange.location + 1)];
                if ([loaderName isEqualToString:@"forge"]) {
                    modLoaderId = @"forge";
                    modLoaderVersion = loaderVer;
                } else if ([loaderName isEqualToString:@"fabric"]) {
                    modLoaderId = @"fabric";
                    modLoaderVersion = [NSString stringWithFormat:@"fabric-loader-%@-%@", loaderVer, vanillaVersion];
                } else {
                    modLoaderId = loaderName;
                    modLoaderVersion = loaderVer;
                }
            } else {
                modLoaderId = rawId;
                modLoaderVersion = rawId;
            }
        }
    }
    NSString *finalVersionString = @"";
    if ([modLoaderId isEqualToString:@"forge"]) {
        finalVersionString = [NSString stringWithFormat:@"%@-forge-%@", vanillaVersion, modLoaderVersion];
    } else if ([modLoaderId isEqualToString:@"fabric"]) {
        finalVersionString = modLoaderVersion;
    } else {
        finalVersionString = [NSString stringWithFormat:@"%@ | %@", vanillaVersion, modLoaderId];
    }
    NSLog(@"downloader: Determined version string: %@", finalVersionString);
    
    // Call the ModloaderInstaller to write installer info to the modpack folder.
    NSError *installerError = nil;
    BOOL successInstaller = [ModloaderInstaller createInstallerFileInModpackDirectory:destPath withVersionString:finalVersionString loaderType:modLoaderId error:&installerError];
    if (!successInstaller) {
        NSLog(@"[ModloaderInstaller] Failed to create installer file: %@", installerError.localizedDescription);
    }
}

@end
