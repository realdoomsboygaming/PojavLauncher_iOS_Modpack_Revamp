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

#pragma mark - Generic GET Endpoint

- (id)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params {
    // Build URL: https://api.curseforge.com/v1/<endpoint>?...
    NSString *baseURL = @"https://api.curseforge.com/v1";
    NSString *fullURL = [baseURL stringByAppendingPathComponent:endpoint];
    
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
    [request setValue:self.apiKey forHTTPHeaderField:@"x-api-key"];
    [request setValue:@"Mozilla/5.0" forHTTPHeaderField:@"User-Agent"];
    
    // Synchronous request using semaphore
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
                      previousPageResult:(NSMutableArray *)previousResults {
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    params[@"gameId"] = @(kCurseForgeGameIDMinecraft);
    
    BOOL isModpack = [searchFilters[@"isModpack"] boolValue];
    params[@"classId"] = isModpack ? @(kCurseForgeClassIDModpack) : @(kCurseForgeClassIDMod);
    
    NSString *searchName = ([searchFilters[@"name"] isKindOfClass:[NSString class]] ?
                            searchFilters[@"name"] : @"");
    params[@"searchFilter"] = searchName;
    
    // Sort by popularity
    params[@"sortField"] = @(1);
    params[@"sortOrder"] = @"desc";
    
    int limit = 50;
    params[@"pageSize"] = @(limit);
    
    // Reset offset if new search term
    NSString *lastSearchName = self.lastSearchTerm ?: @"";
    if (!previousResults || ![searchName isEqualToString:lastSearchName]) {
        self.previousOffset = 0;
        self.reachedLastPage = NO;
    }
    params[@"index"] = @(self.previousOffset);
    
    // Optionally add a gameVersion filter
    NSString *mcVersion = ([searchFilters[@"mcVersion"] isKindOfClass:[NSString class]] ?
                           searchFilters[@"mcVersion"] : nil);
    if (mcVersion.length > 0) {
        params[@"gameVersion"] = mcVersion;
    }
    
    NSDictionary *response = [self getEndpoint:@"mods/search" params:params];
    if (!response) {
        return nil;
    }
    
    NSArray *dataArray = response[@"data"];
    if (![dataArray isKindOfClass:[NSArray class]]) {
        return nil;
    }
    
    NSDictionary *pagination = response[@"pagination"];
    NSUInteger totalCount = 0;
    if ([pagination isKindOfClass:[NSDictionary class]]) {
        NSNumber *tc = pagination[@"totalCount"];
        if ([tc isKindOfClass:[NSNumber class]]) {
            totalCount = tc.unsignedIntegerValue;
        }
    }
    
    NSMutableArray *results = previousResults ?: [NSMutableArray array];
    for (NSDictionary *modDict in dataArray) {
        if (![modDict isKindOfClass:[NSDictionary class]]) continue;
        
        id allowDist = modDict[@"allowModDistribution"];
        if ([allowDist isKindOfClass:[NSNumber class]] && ![allowDist boolValue]) {
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
        NSDictionary *logoDict = ([modDict[@"logo"] isKindOfClass:[NSDictionary class]] ?
                                  modDict[@"logo"] : nil);
        if ([logoDict[@"thumbnailUrl"] isKindOfClass:[NSString class]]) {
            imageUrl = logoDict[@"thumbnailUrl"];
        }
        
        NSMutableDictionary *item = [@{
            @"apiSource": @(0),
            @"isModpack": @(isModpack),
            @"id": modId,
            @"title": title,
            @"description": summary,
            @"imageUrl": imageUrl
        } mutableCopy];
        
        [results addObject:item];
    }
    
    self.previousOffset += dataArray.count;
    if (dataArray.count < limit || results.count >= totalCount) {
        self.reachedLastPage = YES;
    }
    
    self.lastSearchTerm = searchName;
    return results;
}

#pragma mark - Load Mod Details

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    NSString *modId = item[@"id"];
    if (modId.length == 0) return;
    
    NSMutableArray<NSDictionary *> *allFiles = [NSMutableArray array];
    NSInteger pageOffset = 0;
    BOOL endReached = NO;
    
    while (!endReached) {
        NSDictionary *params = @{@"index": @(pageOffset), @"pageSize": @(50)};
        NSString *endpoint = [NSString stringWithFormat:@"mods/%@/files", modId];
        NSDictionary *resp = [self getEndpoint:endpoint params:params];
        if (!resp) return;
        NSArray *data = resp[@"data"];
        if (![data isKindOfClass:[NSArray class]]) return;
        
        int addedCount = 0;
        for (NSDictionary *fileInfo in data) {
            if (![fileInfo isKindOfClass:[NSDictionary class]]) continue;
            if ([fileInfo[@"isServerPack"] boolValue]) continue;
            [allFiles addObject:fileInfo];
            addedCount++;
        }
        if (data.count < 50) {
            endReached = YES;
        } else {
            pageOffset += data.count;
        }
        if (addedCount == 0 && data.count == 50) break;
    }
    
    NSMutableArray<NSString *> *versionNames = [NSMutableArray arrayWithCapacity:allFiles.count];
    NSMutableArray<NSString *> *mcVersions = [NSMutableArray arrayWithCapacity:allFiles.count];
    NSMutableArray<NSString *> *versionUrls = [NSMutableArray arrayWithCapacity:allFiles.count];
    NSMutableArray<NSString *> *hashes = [NSMutableArray arrayWithCapacity:allFiles.count];
    
    for (NSDictionary *fileDict in allFiles) {
        NSString *displayName = (fileDict[@"displayName"] ?: @"");
        [versionNames addObject:displayName];
        
        NSArray *gv = ([fileDict[@"gameVersions"] isKindOfClass:[NSArray class]] ? fileDict[@"gameVersions"] : @[]);
        NSString *firstMC = (gv.count > 0 ? gv.firstObject : @"");
        [mcVersions addObject:firstMC];
        
        NSString *dlUrl = fileDict[@"downloadUrl"];
        if (![dlUrl isKindOfClass:[NSString class]]) {
            dlUrl = @"";
        }
        [versionUrls addObject:dlUrl];
        
        NSString *sha1 = [self getSha1FromFileDict:fileDict];
        [hashes addObject:(sha1 ?: @"")];
    }
    
    item[@"versionNames"] = versionNames;
    item[@"mcVersionNames"] = mcVersions;
    item[@"versionUrls"] = versionUrls;
    item[@"versionHashes"] = hashes;
    item[@"versionDetailsLoaded"] = @(YES);
}

- (NSString *)getSha1FromFileDict:(NSDictionary *)fileDict {
    NSArray *hashArray = fileDict[@"hashes"];
    if (![hashArray isKindOfClass:[NSArray class]]) return nil;
    for (NSDictionary *hashObj in hashArray) {
        if (![hashObj isKindOfClass:[NSDictionary class]]) continue;
        if ([hashObj[@"algo"] intValue] == 1) {
            return hashObj[@"value"];
        }
    }
    return nil;
}

#pragma mark - Install Modpack

- (void)installModpackFromDetail:(NSDictionary *)detail atIndex:(NSInteger)index {
    // Post notification so that the installer (listener) picks up the download task.
    NSDictionary *userInfo = @{
        @"detail": detail,
        @"index": @(index),
        @"source": @(0)  // 0 indicates CurseForge
    };
    [[NSNotificationCenter defaultCenter] postNotificationName:@"InstallModpack"
                                                        object:self
                                                      userInfo:userInfo];
}

- (void)downloader:(MinecraftResourceDownloadTask *)downloader
submitDownloadTasksFromPackage:(NSString *)packagePath
            toPath:(NSString *)destPath {
    NSError *error;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:
         [NSString stringWithFormat:@"[CurseForgeAPI] Failed to open .zip: %@", error.localizedDescription]];
        return;
    }
    
    NSData *manifestData = [archive extractDataFromFile:@"manifest.json" error:&error];
    if (!manifestData || error) {
        [downloader finishDownloadWithErrorString:@"[CurseForgeAPI] No manifest.json in CF modpack"];
        return;
    }
    NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:&error];
    if (!manifest || error) {
        [downloader finishDownloadWithErrorString:
         [NSString stringWithFormat:@"[CurseForgeAPI] Invalid manifest.json: %@", error.localizedDescription]];
        return;
    }
    
    NSArray *filesArr = manifest[@"files"];
    if (![filesArr isKindOfClass:[NSArray class]]) {
        [downloader finishDownloadWithErrorString:@"[CurseForgeAPI] No 'files' array in manifest.json"];
        return;
    }
    downloader.progress.totalUnitCount = filesArr.count;
    
    for (NSDictionary *cfFile in filesArr) {
        NSNumber *projID = cfFile[@"projectID"];
        NSNumber *fileID = cfFile[@"fileID"];
        BOOL required = [cfFile[@"required"] boolValue];
        
        // Attempt to obtain a download URL using the proper endpoint.
        NSString *downloadUrl = [self getDownloadURLForProject:projID file:fileID];
        if (!downloadUrl && required) {
            [downloader finishDownloadWithErrorString:
             [NSString stringWithFormat:@"[CurseForgeAPI] Could not obtain download URL for project %@, file %@", projID, fileID]];
            return;
        } else if (!downloadUrl) {
            downloader.progress.completedUnitCount++;
            continue;
        }
        
        NSString *fileName = downloadUrl.lastPathComponent;
        NSString *destModPath = [destPath stringByAppendingPathComponent:
                                 [NSString stringWithFormat:@"mods/%@", fileName]];
        
        NSString *sha1 = [self getSha1ForProject:projID file:fileID];
        
        NSURLSessionDownloadTask *subTask = [downloader createDownloadTask:downloadUrl
                                                                     size:0
                                                                      sha:sha1
                                                                  altName:nil
                                                                   toPath:destModPath];
        if (subTask) {
            NSString *relPath = [NSString stringWithFormat:@"mods/%@", fileName];
            [downloader.fileList addObject:relPath];
            [subTask resume];
        } else if (!downloader.progress.cancelled) {
            downloader.progress.completedUnitCount++;
        } else {
            return;
        }
    }
    
    // Extract overrides from the archive.
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
    
    // Clean up the downloaded modpack package.
    [[NSFileManager defaultManager] removeItemAtPath:packagePath error:nil];
    
    // Create or update the profile in PLProfiles.
    NSString *packName = ([manifest[@"name"] isKindOfClass:[NSString class]] ? manifest[@"name"] : @"CF_Pack");
    NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
    NSData *iconData = [NSData dataWithContentsOfFile:tmpIconPath];
    NSString *iconBase64 = iconData ? [iconData base64EncodedStringWithOptions:0] : @"";
    
    NSDictionary *minecraftDict = manifest[@"minecraft"];
    NSString *depID = @"";
    if ([minecraftDict isKindOfClass:[NSDictionary class]]) {
        NSArray *modLoaders = minecraftDict[@"modLoaders"];
        if ([modLoaders isKindOfClass:[NSArray class]] && modLoaders.count > 0) {
            NSDictionary *loaderObj = modLoaders.firstObject;
            if ([loaderObj[@"id"] isKindOfClass:[NSString class]]) {
                depID = loaderObj[@"id"];
            }
        }
    }
    
    PLProfiles *profiles = [PLProfiles current];
    profiles.profiles[packName] = [@{
        @"gameDir": [NSString stringWithFormat:@"./custom_gamedir/%@", destPath.lastPathComponent],
        @"name": packName,
        @"lastVersionId": depID ?: @"",
        @"icon": [NSString stringWithFormat:@"data:image/png;base64,%@", iconBase64]
    } mutableCopy];
    
    profiles.selectedProfileName = packName;
    NSLog(@"[CurseForgeAPI] CF modpack installed: %@", packName);
}

#pragma mark - Download URL & SHA Helpers

- (NSString *)getDownloadURLForProject:(NSNumber *)projID file:(NSNumber *)fileID {
    if (!projID || !fileID) return nil;
    NSDictionary *params = @{@"gameId": @(kCurseForgeGameIDMinecraft)};
    NSString *endpoint = [NSString stringWithFormat:@"mods/%@/files/%@/download-url", projID, fileID];
    NSDictionary *resp = [self getEndpoint:endpoint params:params];
    if (![resp isKindOfClass:[NSDictionary class]]) return nil;
    
    id dataVal = resp[@"data"];
    if ([dataVal isKindOfClass:[NSString class]] && ((NSString *)dataVal).length > 0) {
        return dataVal;
    }
    
    // Fallback: fetch file details and construct the download URL manually.
    endpoint = [NSString stringWithFormat:@"mods/%@/files/%@", projID, fileID];
    NSDictionary *fallback = [self getEndpoint:endpoint params:params];
    NSDictionary *fallbackData = fallback[@"data"];
    if ([fallbackData isKindOfClass:[NSDictionary class]]) {
        NSNumber *fID = fallbackData[@"id"];
        NSString *fileName = fallbackData[@"fileName"];
        if (fID && fileName) {
            int numericId = [fID intValue];
            int prefix = numericId / 1000;
            int suffix = numericId % 1000;
            // Use %03d to zero-pad the suffix to three digits.
            return [NSString stringWithFormat:@"https://edge.forgecdn.net/files/%d/%03d/%@", prefix, suffix, fileName];
        }
    }
    return nil;
}

- (NSString *)getSha1ForProject:(NSNumber *)projID file:(NSNumber *)fileID {
    if (!projID || !fileID) return nil;
    NSDictionary *params = @{@"gameId": @(kCurseForgeGameIDMinecraft)};
    NSString *endpoint = [NSString stringWithFormat:@"mods/%@/files/%@", projID, fileID];
    NSDictionary *resp = [self getEndpoint:endpoint params:params];
    NSDictionary *data = resp[@"data"];
    if (![data isKindOfClass:[NSDictionary class]]) return nil;
    return [self getSha1FromFileDict:data];
}

@end
