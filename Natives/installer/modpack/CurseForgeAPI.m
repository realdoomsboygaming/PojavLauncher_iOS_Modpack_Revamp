#import "CurseForgeAPI.h"
#import "MinecraftResourceDownloadTask.h"
#import "ModpackUtils.h"
#import "PLProfiles.h"
#import "UZKArchive.h"
#import <SafariServices/SafariServices.h>

static const NSInteger kCurseForgeGameIDMinecraft = 432;
static const NSInteger kCurseForgeClassIDModpack  = 4471;
static const NSInteger kCurseForgeClassIDMod      = 6;

@interface CurseForgeAPI ()
// Used for fallback integrated browser when errors occur.
@property (nonatomic, strong) NSString *fallbackZipUrl;
// Pending modpack detail and index – used to defer download until user confirms.
@property (nonatomic, strong) NSDictionary *pendingModpackDetail;
@property (nonatomic, assign) NSInteger pendingModpackIndex;
@end

@implementation CurseForgeAPI

#pragma mark - Init

- (instancetype)initWithAPIKey:(NSString *)apiKey {
    self = [super init];
    if (self) {
        _apiKey = [apiKey copy];
        _previousOffset = 0;
        _reachedLastPage = NO;
        _lastSearchTerm = nil;
        _fallbackZipUrl = nil;
        _pendingModpackDetail = nil;
        _pendingModpackIndex = 0;
    }
    return self;
}

#pragma mark - Generic GET Endpoint

- (id)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params {
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
    
    NSString *searchName = ([searchFilters[@"name"] isKindOfClass:[NSString class]] ? searchFilters[@"name"] : @"");
    params[@"searchFilter"] = searchName;
    
    params[@"sortField"] = @(1);
    params[@"sortOrder"] = @"desc";
    
    int limit = 50;
    params[@"pageSize"] = @(limit);
    
    NSString *lastSearchName = self.lastSearchTerm ?: @"";
    if (!previousResults || ![searchName isEqualToString:lastSearchName]) {
        self.previousOffset = 0;
        self.reachedLastPage = NO;
    }
    params[@"index"] = @(self.previousOffset);
    
    NSString *mcVersion = ([searchFilters[@"mcVersion"] isKindOfClass:[NSString class]] ? searchFilters[@"mcVersion"] : nil);
    if (mcVersion.length > 0) {
        params[@"gameVersion"] = mcVersion;
    }
    
    NSDictionary *response = [self getEndpoint:@"mods/search" params:params];
    if (!response) return nil;
    
    NSArray *dataArray = response[@"data"];
    if (![dataArray isKindOfClass:[NSArray class]]) return nil;
    
    NSDictionary *paginationInfo = response[@"pagination"];
    NSUInteger totalCount = 0;
    if ([paginationInfo isKindOfClass:[NSDictionary class]]) {
        NSNumber *tc = paginationInfo[@"totalCount"];
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
        NSDictionary *logoDict = ([modDict[@"logo"] isKindOfClass:[NSDictionary class]] ? modDict[@"logo"] : nil);
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
    // Retrieve the modpack zip URL from the mod detail.
    NSArray *urls = detail[@"versionUrls"];
    if (![urls isKindOfClass:[NSArray class]] || index < 0 || index >= urls.count) {
        NSLog(@"[CurseForgeAPI] No valid versionUrls or invalid index %ld", (long)index);
        return;
    }
    NSString *zipUrlString = urls[index];
    if (zipUrlString.length == 0) {
        NSLog(@"[CurseForgeAPI] Empty zipUrl at index %ld, falling back to browser", (long)index);
        [self fallbackOpenBrowserWithURL:zipUrlString];
        return;
    }
    NSURL *zipURL = [NSURL URLWithString:zipUrlString];
    if (!zipURL) {
        NSLog(@"[CurseForgeAPI] Could not parse zip URL: %@, falling back to browser", zipUrlString);
        [self fallbackOpenBrowserWithURL:zipUrlString];
        return;
    }
    // Save the zip URL for fallback purposes.
    self.fallbackZipUrl = zipUrlString;
    
    // Instead of starting the download immediately, store the modpack detail and version index
    // and notify the UI that the modpack is ready to be played.
    self.pendingModpackDetail = detail;
    self.pendingModpackIndex = index;
    
    // Notify the UI (via notification) that the modpack is ready for user to press "Play".
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ModpackReadyForPlay" object:self];
}

- (void)startPendingDownload {
    if (!self.pendingModpackDetail) {
        NSLog(@"startPendingDownload: No pending modpack detail available");
        return;
    }
    NSDictionary *detail = self.pendingModpackDetail;
    NSInteger index = self.pendingModpackIndex;
    NSDictionary *userInfo = @{
        @"detail": detail,
        @"index": @(index),
        @"source": @(0)  // 0 indicates CurseForge
    };
    [[NSNotificationCenter defaultCenter] postNotificationName:@"InstallModpack" object:self userInfo:userInfo];
    // Clear pending detail after starting download.
    self.pendingModpackDetail = nil;
    self.pendingModpackIndex = 0;
}

- (void)fallbackOpenBrowserWithURL:(NSString *)urlString {
    if (!urlString || urlString.length == 0) return;
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return;
    if (self.parentViewController) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SFSafariViewController *safariVC = [[SFSafariViewController alloc] initWithURL:url];
            [self.parentViewController presentViewController:safariVC animated:YES completion:nil];
        });
    }
}

- (void)downloader:(MinecraftResourceDownloadTask *)downloader
submitDownloadTasksFromPackage:(NSString *)packagePath
            toPath:(NSString *)destPath {
    // Offload heavy file operations to a background queue.
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error;
        UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"[CurseForgeAPI] Failed to open modpack package: %@", error.localizedDescription]];
                [self fallbackOpenBrowserWithURL:self.fallbackZipUrl];
            });
            return;
        }
        
        NSData *manifestData = [archive extractDataFromFile:@"manifest.json" error:&error];
        if (!manifestData || error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [downloader finishDownloadWithErrorString:@"[CurseForgeAPI] No manifest.json in modpack package"];
                [self fallbackOpenBrowserWithURL:self.fallbackZipUrl];
            });
            return;
        }
        NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:&error];
        if (!manifest || error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"[CurseForgeAPI] Invalid manifest.json: %@", error.localizedDescription]];
                [self fallbackOpenBrowserWithURL:self.fallbackZipUrl];
            });
            return;
        }
        
        // Verify manifest – must be a valid minecraftModpack.
        if (!([manifest[@"manifestType"] isEqualToString:@"minecraftModpack"] &&
              [manifest[@"manifestVersion"] integerValue] == 1 &&
              manifest[@"minecraft"] &&
              [manifest[@"minecraft"] isKindOfClass:[NSDictionary class]] &&
              manifest[@"minecraft"][@"modLoaders"] &&
              [manifest[@"minecraft"][@"modLoaders"] isKindOfClass:[NSArray class]] &&
              [manifest[@"minecraft"][@"modLoaders"] count] > 0)) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [downloader finishDownloadWithErrorString:@"[CurseForgeAPI] Manifest verification failed"];
                [self fallbackOpenBrowserWithURL:self.fallbackZipUrl];
            });
            return;
        }
        
        NSArray *filesArr = manifest[@"files"];
        if (![filesArr isKindOfClass:[NSArray class]]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [downloader finishDownloadWithErrorString:@"[CurseForgeAPI] No 'files' array in manifest.json"];
                [self fallbackOpenBrowserWithURL:self.fallbackZipUrl];
            });
            return;
        }
        downloader.progress.totalUnitCount = filesArr.count;
        
        // Limit concurrent downloads to 5.
        dispatch_semaphore_t downloadSemaphore = dispatch_semaphore_create(5);
        
        for (NSDictionary *cfFile in filesArr) {
            NSNumber *projID = cfFile[@"projectID"];
            NSNumber *fileID = cfFile[@"fileID"];
            BOOL required = [cfFile[@"required"] boolValue];
            
            dispatch_semaphore_wait(downloadSemaphore, DISPATCH_TIME_FOREVER);
            NSString *downloadUrl = [self getDownloadURLForProject:projID file:fileID];
            if (!downloadUrl && required) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [downloader finishDownloadWithErrorString:
                     [NSString stringWithFormat:@"[CurseForgeAPI] Could not obtain download URL for project %@, file %@", projID, fileID]];
                    [self fallbackOpenBrowserWithURL:self.fallbackZipUrl];
                });
                dispatch_semaphore_signal(downloadSemaphore);
                return;
            } else if (!downloadUrl) {
                downloader.progress.completedUnitCount++;
                dispatch_semaphore_signal(downloadSemaphore);
                continue;
            }
            
            NSString *fileName = downloadUrl.lastPathComponent;
            NSString *destModPath = [destPath stringByAppendingPathComponent:[NSString stringWithFormat:@"mods/%@", fileName]];
            
            NSString *sha1 = [self getSha1ForProject:projID file:fileID];
            NSURLSessionDownloadTask *subTask = [downloader createDownloadTask:downloadUrl
                                                                         size:0
                                                                          sha:sha1
                                                                      altName:nil
                                                                       toPath:destModPath];
            if (subTask) {
                [downloader.fileList addObject:[NSString stringWithFormat:@"mods/%@", fileName]];
                [subTask addObserver:self forKeyPath:@"state" options:NSKeyValueObservingOptionNew context:(__bridge void *)downloadSemaphore];
                [subTask resume];
            } else if (!downloader.progress.cancelled) {
                downloader.progress.completedUnitCount++;
                dispatch_semaphore_signal(downloadSemaphore);
            } else {
                dispatch_semaphore_signal(downloadSemaphore);
                return;
            }
        }
        
        // Extract overrides folder.
        NSString *overridesDir = @"overrides";
        if ([manifest[@"overrides"] isKindOfClass:[NSString class]] && [manifest[@"overrides"] length] > 0) {
            overridesDir = manifest[@"overrides"];
        }
        [ModpackUtils archive:archive extractDirectory:overridesDir toPath:destPath error:&error];
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [downloader finishDownloadWithErrorString:
                 [NSString stringWithFormat:@"[CurseForgeAPI] Could not extract overrides: %@", error.localizedDescription]];
                [self fallbackOpenBrowserWithURL:self.fallbackZipUrl];
            });
            return;
        }
        
        // Cleanup: Delete the modpack zip.
        [[NSFileManager defaultManager] removeItemAtPath:packagePath error:nil];
        
        // Update profile with modpack info on the main thread.
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *packName = ([manifest[@"name"] isKindOfClass:[NSString class]] ? manifest[@"name"] : @"CF_Pack");
            NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
            NSData *iconData = [NSData dataWithContentsOfFile:tmpIconPath];
            NSString *iconBase64 = iconData ? [iconData base64EncodedStringWithOptions:0] : @"";
            
            NSDictionary *minecraftDict = manifest[@"minecraft"];
            NSString *depID = @"";
            if ([minecraftDict isKindOfClass:[NSDictionary class]]) {
                NSArray *modLoaders = minecraftDict[@"modLoaders"];
                if ([modLoaders isKindOfClass:[NSArray class]] && modLoaders.count > 0) {
                    NSDictionary *primaryModLoader = nil;
                    for (NSDictionary *loader in modLoaders) {
                        if ([loader[@"primary"] boolValue]) {
                            primaryModLoader = loader;
                            break;
                        }
                    }
                    if (!primaryModLoader) {
                        primaryModLoader = modLoaders.firstObject;
                    }
                    if ([primaryModLoader[@"id"] isKindOfClass:[NSString class]]) {
                        depID = primaryModLoader[@"id"];
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
        });
    });
}

#pragma mark - KVO for Download Task Completion

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
    if ([keyPath isEqualToString:@"state"]) {
        NSURLSessionDownloadTask *task = object;
        if (task.state == NSURLSessionTaskStateCompleted) {
            dispatch_semaphore_t downloadSemaphore = (__bridge dispatch_semaphore_t)context;
            dispatch_semaphore_signal(downloadSemaphore);
            [object removeObserver:self forKeyPath:@"state" context:context];
        }
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

#pragma mark - Download URL & SHA Helpers

- (NSString *)getDownloadURLForProject:(NSNumber *)projID file:(NSNumber *)fileID {
    if (!projID || !fileID) {
        NSLog(@"getDownloadURLForProject: Missing projID or fileID");
        return nil;
    }
    NSDictionary *params = @{@"gameId": @(kCurseForgeGameIDMinecraft)};
    NSString *endpoint = [NSString stringWithFormat:@"mods/%@/files/%@/download-url", projID, fileID];
    NSDictionary *resp = [self getEndpoint:endpoint params:params];
    NSLog(@"getDownloadURLForProject: Response from %@: %@", endpoint, resp);
    if (![resp isKindOfClass:[NSDictionary class]]) {
        NSLog(@"getDownloadURLForProject: Response is not a dictionary");
        return nil;
    }
    
    id dataVal = resp[@"data"];
    if ([dataVal isKindOfClass:[NSString class]] && ((NSString *)dataVal).length > 0) {
        NSLog(@"getDownloadURLForProject: Retrieved URL: %@", dataVal);
        return dataVal;
    }
    
    // Fallback: fetch file details and construct URL manually.
    endpoint = [NSString stringWithFormat:@"mods/%@/files/%@", projID, fileID];
    NSDictionary *fallback = [self getEndpoint:endpoint params:params];
    NSLog(@"getDownloadURLForProject: Fallback response from %@: %@", endpoint, fallback);
    NSDictionary *fallbackData = fallback[@"data"];
    if ([fallbackData isKindOfClass:[NSDictionary class]]) {
        NSNumber *fID = fallbackData[@"id"];
        NSString *fileName = fallbackData[@"fileName"];
        if (fID && fileName) {
            int numericId = [fID intValue];
            int prefix = numericId / 1000;
            int suffix = numericId % 1000;
            NSString *constructedURL = [NSString stringWithFormat:@"https://edge.forgecdn.net/files/%d/%03d/%@", prefix, suffix, fileName];
            NSLog(@"getDownloadURLForProject: Constructed fallback URL: %@", constructedURL);
            return constructedURL;
        }
    }
    NSLog(@"getDownloadURLForProject: Could not obtain a download URL");
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
