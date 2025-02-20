#import "CurseForgeAPI.h"
#import "MinecraftResourceDownloadTask.h"
#import "ModpackUtils.h"
#import "PLProfiles.h"
#import "UZKArchive.h"

static const NSInteger kCurseForgeGameIDMinecraft = 432;
static const NSInteger kCurseForgeClassIDModpack  = 4471;
static const NSInteger kCurseForgeClassIDMod      = 6;

@implementation CurseForgeAPI

#pragma mark - Init

- (instancetype)initWithAPIKey:(NSString *)apiKey {
    self = [super init];
    if (self) {
        _apiKey = [apiKey copy];
        _previousOffset = 0;
        _reachedLastPage = NO;
        _lastSearchTerm = nil;
    }
    return self;
}

#pragma mark - getEndpoint

- (id)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params {
    // Build URL: https://api.curseforge.com/v1/<endpoint>?...
    NSString *baseURL = @"https://api.curseforge.com/v1";
    NSString *fullURL = [baseURL stringByAppendingPathComponent:endpoint];

    // Turn params into a query string
    NSURLComponents *components = [NSURLComponents componentsWithString:fullURL];
    if ([params isKindOfClass:[NSDictionary class]]) {
        NSMutableArray<NSURLQueryItem *> *queryItems = [NSMutableArray array];
        for (NSString *key in params) {
            NSString *valString = [NSString stringWithFormat:@"%@", params[key]];
            [queryItems addObject:[NSURLQueryItem queryItemWithName:key value:valString]];
        }
        components.queryItems = queryItems;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL];
    // The CF API key goes in "x-api-key"
    [request setValue:self.apiKey forHTTPHeaderField:@"x-api-key"];
    [request setValue:@"Mozilla/5.0" forHTTPHeaderField:@"User-Agent"];

    // Perform synchronous request
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block id resultObj = nil;
    __block NSError *reqError = nil;

    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
      dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error)
    {
        if (error) {
            reqError = error;
        } else if (data) {
            NSError *jsonErr = nil;
            id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
            if (jsonErr) {
                reqError = jsonErr;
            } else {
                resultObj = parsed;
            }
        }
        dispatch_semaphore_signal(sem);
    }];

    [task resume];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

    if (reqError) {
        self.lastError = reqError;
        return nil;
    }
    return resultObj;
}

#pragma mark - Search

- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, id> *)searchFilters
                      previousPageResult:(NSMutableArray *)previousResults
{
    // Build query
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    params[@"gameId"] = @(kCurseForgeGameIDMinecraft);

    BOOL isModpack = [searchFilters[@"isModpack"] boolValue];
    params[@"classId"] = isModpack ? @(kCurseForgeClassIDModpack) : @(kCurseForgeClassIDMod);

    // Extract search name
    NSString *searchName = ([searchFilters[@"name"] isKindOfClass:[NSString class]]
                            ? searchFilters[@"name"]
                            : @"");
    params[@"searchFilter"] = searchName;

    // Sort by popularity
    params[@"sortField"] = @(1);   // 1 => "Popularity" in CurseForge docs
    params[@"sortOrder"] = @"desc";

    int limit = 50;
    params[@"pageSize"] = @(limit);

    // If brand-new search text, reset offset
    NSString *lastSearchName = self.lastSearchTerm ?: @"";
    if (!previousResults || ![searchName isEqualToString:lastSearchName]) {
        self.previousOffset = 0;
        self.reachedLastPage = NO;
    }
    params[@"index"] = @(self.previousOffset);

    // If a specific MC version is specified
    NSString *mcVersion = ([searchFilters[@"mcVersion"] isKindOfClass:[NSString class]]
                           ? searchFilters[@"mcVersion"] : nil);
    if (mcVersion.length > 0) {
        params[@"gameVersion"] = mcVersion;
    }

    // GET /mods/search
    NSDictionary *response = [self getEndpoint:@"mods/search" params:params];
    if (!response) {
        // self.lastError likely set
        return nil;
    }

    NSArray *dataArray = response[@"data"];
    if (![dataArray isKindOfClass:[NSArray class]]) {
        return nil;
    }

    // We also want to read "totalCount" from "pagination" => "totalCount"
    NSDictionary *pagination = response[@"pagination"];
    NSUInteger totalCount = 0;
    if ([pagination isKindOfClass:[NSDictionary class]]) {
        NSNumber *tc = pagination[@"totalCount"];
        if ([tc isKindOfClass:[NSNumber class]]) {
            totalCount = tc.unsignedIntegerValue;
        }
    }

    // If we have previous results, build onto them. Otherwise, new array
    NSMutableArray *results = previousResults ?: [NSMutableArray array];

    // For each item in "data", create a dictionary
    for (NSDictionary *modDict in dataArray) {
        if (![modDict isKindOfClass:[NSDictionary class]]) continue;

        // Skip if "allowModDistribution" is false (like your Android code)
        id allowDist = modDict[@"allowModDistribution"];
        if ([allowDist isKindOfClass:[NSNumber class]] && ![allowDist boolValue]) {
            // If it's explicitly false, skip
            NSLog(@"[CurseForgeAPI] Skipping modpack because allowModDistribution=false");
            continue;
        }

        id modIdValue = modDict[@"id"];
        NSString *modId = @"";
        if ([modIdValue respondsToSelector:@selector(stringValue)]) {
            modId = [modIdValue stringValue];
        }
        NSString *title = ([modDict[@"name"] isKindOfClass:[NSString class]] ? modDict[@"name"] : @"");
        NSString *summary = ([modDict[@"summary"] isKindOfClass:[NSString class]] ? modDict[@"summary"] : @"");
        NSString *imageUrl = @"";
        NSDictionary *logoDict = ([modDict[@"logo"] isKindOfClass:[NSDictionary class]]
                                  ? modDict[@"logo"] : nil);
        if ([logoDict[@"thumbnailUrl"] isKindOfClass:[NSString class]]) {
            imageUrl = logoDict[@"thumbnailUrl"];
        }

        NSMutableDictionary *item = [@{
            @"apiSource": @(0),  // 0 => CurseForge
            @"isModpack": @(isModpack),
            @"id": modId,
            @"title": title,
            @"description": summary,
            @"imageUrl": imageUrl
        } mutableCopy];

        [results addObject:item];
    }

    self.previousOffset += dataArray.count;
    // If we have fewer items than 'limit' or we've reached the totalCount, we’re done
    if (dataArray.count < limit || results.count >= totalCount) {
        self.reachedLastPage = YES;
    }

    // Store the search term
    self.lastSearchTerm = searchName;
    return results;
}

#pragma mark - loadDetailsOfMod

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    // The Android code fetches all the non-serverpack files from /mods/:id/files (paginated).
    // We'll do the same to build "versionNames", "mcVersionNames", "versionUrls", "hashes", etc.
    NSString *modId = item[@"id"];
    if (modId.length == 0) return;

    // We'll gather an array of all files
    NSMutableArray<NSDictionary *> *allFiles = [NSMutableArray array];
    NSInteger pageOffset = 0;
    BOOL endReached = NO;

    while (!endReached) {
        NSDictionary *params = @{
            @"index": @(pageOffset),
            @"pageSize": @(50)
        };
        NSString *endpoint = [NSString stringWithFormat:@"mods/%@/files", modId];
        NSDictionary *resp = [self getEndpoint:endpoint params:params];
        if (!resp) {
            // error => bail
            return;
        }
        NSArray *data = resp[@"data"];
        if (![data isKindOfClass:[NSArray class]]) {
            return;
        }
        // For each file, skip if isServerPack = true
        int addedCount = 0;
        for (NSDictionary *fileInfo in data) {
            if (![fileInfo isKindOfClass:[NSDictionary class]]) continue;
            if ([fileInfo[@"isServerPack"] boolValue]) {
                // skip server packs
                continue;
            }
            [allFiles addObject:fileInfo];
            addedCount++;
        }
        if (data.count < 50) {
            // reached last page
            endReached = YES;
        } else {
            pageOffset += data.count;
        }
        // If we added zero this page, we risk infinite looping => break
        if (addedCount == 0 && data.count == 50) {
            // If we got 50 but all were server packs => next page
            // We keep going, but if that continues, we might be stuck in a loop
            // We'll assume eventually we find a non-server pack or we hit a short page
        }
    }

    // Build the standard arrays
    NSMutableArray<NSString *> *versionNames = [NSMutableArray arrayWithCapacity:allFiles.count];
    NSMutableArray<NSString *> *mcVersions   = [NSMutableArray arrayWithCapacity:allFiles.count];
    NSMutableArray<NSString *> *versionUrls  = [NSMutableArray arrayWithCapacity:allFiles.count];
    NSMutableArray<NSString *> *hashes       = [NSMutableArray arrayWithCapacity:allFiles.count];

    // For each file, find its "displayName", "downloadUrl", "gameVersions" (for MC version),
    // plus we might do a second get to fetch the SHA-1 if needed. We'll skip that if it's in "hashes" directly.
    for (NSDictionary *fileDict in allFiles) {
        NSString *displayName = (fileDict[@"displayName"] ?: @"");
        [versionNames addObject:displayName];

        NSArray *gv = ([fileDict[@"gameVersions"] isKindOfClass:[NSArray class]]
                       ? fileDict[@"gameVersions"]
                       : @[]);
        NSString *firstMC = (gv.count > 0 ? gv.firstObject : @"");
        [mcVersions addObject:firstMC];

        // direct "downloadUrl"
        NSString *dlUrl = fileDict[@"downloadUrl"];
        if (![dlUrl isKindOfClass:[NSString class]]) {
            dlUrl = @"";
        }
        [versionUrls addObject:dlUrl];

        // If you want the SHA1, we can parse "hashes" array from the file object:
        // "hashes" => array of { "value": "...", "algo": 1=sha1 }
        NSString *sha1 = [self getSha1FromFileDict:fileDict];
        [hashes addObject:(sha1 ?: @"")];
    }

    item[@"versionNames"] = versionNames;
    item[@"mcVersionNames"] = mcVersions;
    item[@"versionUrls"] = versionUrls;
    item[@"versionHashes"] = hashes;
}

// Helper to parse the "hashes" array from a file dictionary
- (NSString *)getSha1FromFileDict:(NSDictionary *)fileDict {
    NSArray *hashArray = fileDict[@"hashes"];
    if (![hashArray isKindOfClass:[NSArray class]]) {
        return nil;
    }
    for (NSDictionary *hashObj in hashArray) {
        if (![hashObj isKindOfClass:[NSDictionary class]]) continue;
        // "algo" = 1 => sha1, "value" => ...
        if ([hashObj[@"algo"] intValue] == 1) {
            return hashObj[@"value"];
        }
    }
    return nil;
}

#pragma mark - Install (like Java's "installCurseforgeZip")

- (void)installModpackFromDetail:(NSDictionary *)detail atIndex:(NSInteger)index {
    // We'll do the "download the .zip" approach, but also parse its "manifest.json" => for sub-files
    // => We'll queue each file in "manifest.files" individually with MinecraftResourceDownloadTask.

    // 1) Make sure we have a versionUrls array
    NSArray *urls = detail[@"versionUrls"];
    if (![urls isKindOfClass:[NSArray class]] || index < 0 || index >= urls.count) {
        NSLog(@"[CurseForgeAPI] No valid versionUrls or invalid index %ld", (long)index);
        return;
    }
    NSString *zipUrlString = urls[index];
    if (zipUrlString.length == 0) {
        NSLog(@"[CurseForgeAPI] Empty zipUrl at index %ld", (long)index);
        return;
    }
    NSURL *zipURL = [NSURL URLWithString:zipUrlString];
    if (!zipURL) {
        NSLog(@"[CurseForgeAPI] Could not parse zip url: %@", zipUrlString);
        return;
    }

    // 2) Post a notification so that the iOS code can use a MinecraftResourceDownloadTask.
    // Or do it inline. We'll show the inline approach, mirroring your Modrinth style:
    // But best to keep consistent with your existing "downloader:submitDownloadTasks..." design.
    NSDictionary *userInfo = @{
        @"detail": detail,
        @"index": @(index),
        @"source": @(0)  // 0 => CF
    };
    [[NSNotificationCenter defaultCenter]
        postNotificationName:@"InstallModpack"
                      object:self
                    userInfo:userInfo];
}

// If you use a MinecraftResourceDownloadTask approach, you override the method
// "downloader:submitDownloadTasksFromPackage:toPath:" to parse manifest.json
// and queue each sub-file. Similar to the Android's "installCurseforgeZip(...)".
- (void)downloader:(MinecraftResourceDownloadTask *)downloader
submitDownloadTasksFromPackage:(NSString *)packagePath
            toPath:(NSString *)destPath
{
    // 1) Open the zip with UZKArchive
    NSError *error;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:
          @"[CurseForgeAPI] Failed to open .zip: %@", error.localizedDescription]];
        return;
    }

    // 2) Extract "manifest.json"
    NSData *manifestData = [archive extractDataFromFile:@"manifest.json" error:&error];
    if (!manifestData || error) {
        [downloader finishDownloadWithErrorString:@"[CurseForgeAPI] No manifest.json in CF modpack"];
        return;
    }
    NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:&error];
    if (!manifest || error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:
          @"[CurseForgeAPI] Invalid manifest.json: %@", error.localizedDescription]];
        return;
    }

    // 3) "files" => array of { projectID, fileID, required }
    NSArray *filesArr = manifest[@"files"];
    if (![filesArr isKindOfClass:[NSArray class]]) {
        [downloader finishDownloadWithErrorString:@"[CurseForgeAPI] No 'files' array in manifest.json"];
        return;
    }

    // We'll set totalUnitCount to the number of sub-file downloads
    downloader.progress.totalUnitCount = filesArr.count;

    // 4) For each file, build a direct download URL and queue with createDownloadTask:
    for (NSDictionary *cfFile in filesArr) {
        // `projectID`, `fileID`
        NSNumber *projID = cfFile[@"projectID"];
        NSNumber *fileID = cfFile[@"fileID"];
        BOOL required = [cfFile[@"required"] boolValue];

        // Build an API call "GET /mods/:projectID/files/:fileID/download-url" to get a direct link
        NSString *downloadUrl = [self getDownloadURLForProject:projID file:fileID];
        if (!downloadUrl && required) {
            // If it's required but we can't get a URL, fail:
            [downloader finishDownloadWithErrorString:
              [NSString stringWithFormat:@"[CurseForgeAPI] Could not obtain download URL for project %@, file %@",
               projID, fileID]];
            return;
        } else if (!downloadUrl) {
            // If not required, we skip it
            downloader.progress.completedUnitCount++;
            continue;
        }

        // We'll guess the final filename from the URL (or from the CF file info).
        NSString *fileName = downloadUrl.lastPathComponent;
        NSString *destModPath = [destPath stringByAppendingPathComponent:
                                 [NSString stringWithFormat:@"mods/%@", fileName]];

        // Optionally fetch the SHA-1 for verification
        NSString *sha1 = [self getSha1ForProject:projID file:fileID];

        // Create & queue the sub-download
        NSURLSessionDownloadTask *subTask = [downloader createDownloadTask:downloadUrl
                                                                     size:0
                                                                      sha:sha1
                                                                  altName:nil
                                                                   toPath:destModPath];
        if (subTask) {
            // Record the relative path in fileList
            NSString *relPath = [NSString stringWithFormat:@"mods/%@", fileName];
            [downloader.fileList addObject:relPath];
            [subTask resume];
        } else if (!downloader.progress.cancelled) {
            // If the subTask is nil but we're not cancelled, increment progress
            downloader.progress.completedUnitCount++;
        } else {
            return; // cancelled
        }
    }

    // 5) Extract overrides
    NSString *overridesDir = manifest[@"overrides"];
    if (![overridesDir isKindOfClass:[NSString class]] || overridesDir.length == 0) {
        overridesDir = @"overrides";
    }
    [ModpackUtils archive:archive extractDirectory:overridesDir toPath:destPath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:
          [NSString stringWithFormat:@"[CurseForgeAPI] Could not extract overrides: %@", error.localizedDescription]];
        return;
    }
    // Some packs also might use "Overrides" => optional.

    // Clean up
    [[NSFileManager defaultManager] removeItemAtPath:packagePath error:nil];

    // 6) Make a profile in PLProfiles
    NSString *packName = ([manifest[@"name"] isKindOfClass:[NSString class]] ? manifest[@"name"] : @"CF_Pack");
    NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
    NSData *iconData = [NSData dataWithContentsOfFile:tmpIconPath];
    NSString *iconBase64 = iconData ? [iconData base64EncodedStringWithOptions:0] : @"";

    // parse out "minecraft" => "version", "modLoaders" => ...
    NSDictionary *minecraftDict = manifest[@"minecraft"];
    NSString *depID = @"";
    if ([minecraftDict isKindOfClass:[NSDictionary class]]) {
        NSArray *modLoaders = minecraftDict[@"modLoaders"];
        if ([modLoaders isKindOfClass:[NSArray class]] && modLoaders.count > 0) {
            NSDictionary *loaderObj = modLoaders.firstObject;
            if ([loaderObj[@"id"] isKindOfClass:[NSString class]]) {
                depID = loaderObj[@"id"]; // e.g. "forge-1.18.2-..."
            }
        }
    }

    PLProfiles *profiles = [PLProfiles current];
    profiles.profiles[packName] = [@{
        @"gameDir": [NSString stringWithFormat:@"./custom_gamedir/%@", destPath.lastPathComponent],
        @"name": packName,
        @"lastVersionId": depID,
        @"icon": [NSString stringWithFormat:@"data:image/png;base64,%@", iconBase64]
    } mutableCopy];

    profiles.selectedProfileName = packName;
    NSLog(@"[CurseForgeAPI] CF modpack installed: %@", packName);
}

#pragma mark - Download URL & SHA helpers

- (NSString *)getDownloadURLForProject:(NSNumber *)projID file:(NSNumber *)fileID {
    if (!projID || !fileID) return nil;
    NSString *endpoint = [NSString stringWithFormat:@"mods/%@/files/%@/download-url",
                          projID, fileID];
    NSDictionary *resp = [self getEndpoint:endpoint params:nil];
    if (![resp isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    id dataVal = resp[@"data"];
    if ([dataVal isKindOfClass:[NSString class]]) {
        // success => direct link
        return dataVal;
    }

    // fallback approach: call "GET /mods/:projID/files/:fileID" to get "fileName"
    endpoint = [NSString stringWithFormat:@"mods/%@/files/%@", projID, fileID];
    NSDictionary *fallback = [self getEndpoint:endpoint params:nil];
    NSDictionary *fallbackData = fallback[@"data"];
    if ([fallbackData isKindOfClass:[NSDictionary class]]) {
        // Build edge.forgecdn.net link
        NSNumber *fID = fallbackData[@"id"];
        NSString *fileName = fallbackData[@"fileName"];
        if (fID && fileName) {
            int numericId = [fID intValue];
            int prefix = numericId / 1000;
            int suffix = numericId % 1000;
            return [NSString stringWithFormat:
              @"https://edge.forgecdn.net/files/%d/%d/%@", prefix, suffix, fileName];
        }
    }
    return nil;
}

- (NSString *)getSha1ForProject:(NSNumber *)projID file:(NSNumber *)fileID {
    // We can call GET /mods/:projID/files/:fileID => parse "hashes"
    if (!projID || !fileID) return nil;
    NSString *endpoint = [NSString stringWithFormat:@"mods/%@/files/%@", projID, fileID];
    NSDictionary *resp = [self getEndpoint:endpoint params:nil];
    NSDictionary *data = resp[@"data"];
    if (![data isKindOfClass:[NSDictionary class]]) {
        return nil;
    }
    return [self getSha1FromFileDict:data];
}

@end
