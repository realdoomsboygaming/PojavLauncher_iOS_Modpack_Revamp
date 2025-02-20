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
// Pending properties to hold manifest and download info until the user presses "Play"
@property (nonatomic, strong) NSDictionary *pendingManifest;
@property (nonatomic, strong) NSString *pendingPackagePath;
@property (nonatomic, strong) NSString *pendingDestinationPath;
@property (nonatomic, strong) NSDictionary *pendingModpackDetail;
@property (nonatomic, assign) NSInteger pendingModpackIndex;

// Private helper method.
- (NSString *)getSha1FromFileDict:(NSDictionary *)fileDict;
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
        _pendingManifest = nil;
        _pendingPackagePath = nil;
        _pendingDestinationPath = nil;
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

#pragma mark - Search & Details

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

#pragma mark - Install Modpack

- (void)installModpackFromDetail:(NSDictionary *)modpackDetail atIndex:(NSInteger)selectedIndex {
    // Retrieve the modpack zip URL from the mod detail.
    NSArray *urls = modpackDetail[@"versionUrls"];
    if (![urls isKindOfClass:[NSArray class]] || selectedIndex < 0 || selectedIndex >= urls.count) {
        NSLog(@"[CurseForgeAPI] No valid versionUrls or invalid index %ld", (long)selectedIndex);
        return;
    }
    NSString *zipUrlString = urls[selectedIndex];
    if (zipUrlString.length == 0) {
        NSLog(@"[CurseForgeAPI] Empty zipUrl at index %ld", (long)selectedIndex);
        [self fallbackOpenBrowserWithURL:zipUrlString];
        return;
    }
    NSURL *zipURL = [NSURL URLWithString:zipUrlString];
    if (!zipURL) {
        NSLog(@"[CurseForgeAPI] Could not parse zip URL: %@, falling back to browser", zipUrlString);
        [self fallbackOpenBrowserWithURL:zipUrlString];
        return;
    }
    self.fallbackZipUrl = zipUrlString;
    
    // Start downloading the modpack zip immediately.
    // Capture the modpack detail and selected index in local variables.
    NSDictionary *modpackDetailCopy = [modpackDetail copy];
    NSInteger selectedIndexCopy = selectedIndex;
    
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    NSURLSessionDownloadTask *downloadTask = [session downloadTaskWithURL:zipURL completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        if (error) {
            NSLog(@"[CurseForgeAPI] Error downloading zip file: %@", error);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self fallbackOpenBrowserWithURL:self.fallbackZipUrl];
            });
            return;
        }
        // Move the downloaded file to a temporary location.
        NSString *tempDir = NSTemporaryDirectory();
        NSString *destinationFilePath = [NSString stringWithFormat:@"%@/modpack_%@", tempDir, modpackDetailCopy[@"id"]];
        [[NSFileManager defaultManager] removeItemAtPath:destinationFilePath error:nil];
        NSError *fileError = nil;
        BOOL success = [[NSFileManager defaultManager] moveItemAtPath:location.path toPath:destinationFilePath error:&fileError];
        if (!success) {
            NSLog(@"[CurseForgeAPI] Error moving zip file: %@", fileError);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self fallbackOpenBrowserWithURL:self.fallbackZipUrl];
            });
            return;
        }
        // Define a destination folder for the modpack profile.
        NSString *customDestPath = [NSString stringWithFormat:@"%s/custom_gamedir/%@", getenv("POJAV_GAME_DIR"), modpackDetailCopy[@"id"]];
        // Process the manifest to create/update the profile.
        [self processManifestFromPackage:[NSURL fileURLWithPath:destinationFilePath] destinationPath:customDestPath downloader:nil];
    }];
    [downloadTask resume];
}

/// Process the modpack manifest: extract, parse, verify, and create/update the profile.
/// Does not start subfile downloads yet.
- (void)processManifestFromPackage:(NSURL *)zipURL destinationPath:(NSString *)destPath downloader:(MinecraftResourceDownloadTask *)downloader {
    NSString *packagePath = zipURL.path;
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error;
        UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (downloader) {
                    [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"[CurseForgeAPI] Failed to open modpack package: %@", error.localizedDescription]];
                }
                [self fallbackOpenBrowserWithURL:self.fallbackZipUrl];
            });
            return;
        }
        
        NSData *manifestData = [archive extractDataFromFile:@"manifest.json" error:&error];
        if (!manifestData || error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (downloader) {
                    [downloader finishDownloadWithErrorString:@"[CurseForgeAPI] No manifest.json in modpack package"];
                }
                [self fallbackOpenBrowserWithURL:self.fallbackZipUrl];
            });
            return;
        }
        NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:&error];
        if (!manifest || error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (downloader) {
                    [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"[CurseForgeAPI] Invalid manifest.json: %@", error.localizedDescription]];
                }
                [self fallbackOpenBrowserWithURL:self.fallbackZipUrl];
            });
            return;
        }
        
        if (!([manifest[@"manifestType"] isEqualToString:@"minecraftModpack"] &&
              [manifest[@"manifestVersion"] integerValue] == 1 &&
              manifest[@"minecraft"] &&
              [manifest[@"minecraft"] isKindOfClass:[NSDictionary class]] &&
              manifest[@"minecraft"][@"modLoaders"] &&
              [manifest[@"minecraft"][@"modLoaders"] isKindOfClass:[NSArray class]] &&
              [manifest[@"minecraft"][@"modLoaders"] count] > 0)) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (downloader) {
                    [downloader finishDownloadWithErrorString:@"[CurseForgeAPI] Manifest verification failed"];
                }
                [self fallbackOpenBrowserWithURL:self.fallbackZipUrl];
            });
            return;
        }
        
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
            
            NSLog(@"[CurseForgeAPI] Profile created for modpack: %@", packName);
            
            // Store pending info for subfile downloads.
            self.pendingManifest = manifest;
            self.pendingPackagePath = packagePath;
            self.pendingDestinationPath = destPath;
            self.pendingModpackDetail = modpackDetail; // Use the modpackDetail captured earlier
            self.pendingModpackIndex = selectedIndex;  // Use the selectedIndex captured earlier
            
            // Notify the UI that the modpack is ready for play.
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ModpackReadyForPlay" object:self];
        });
    });
}

#pragma mark - Start Pending Download

- (void)startPendingDownload {
    if (!self.pendingManifest || !self.pendingPackagePath || !self.pendingDestinationPath) {
        NSLog(@"startPendingDownload: No pending download available");
        return;
    }
    NSArray *filesArr = self.pendingManifest[@"files"];
    if (![filesArr isKindOfClass:[NSArray class]]) {
        NSLog(@"startPendingDownload: Invalid files array");
        return;
    }
    
    dispatch_semaphore_t downloadSemaphore = dispatch_semaphore_create(5);
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        for (NSDictionary *cfFile in filesArr) {
            NSNumber *projID = cfFile[@"projectID"];
            NSNumber *fileID = cfFile[@"fileID"];
            BOOL required = [cfFile[@"required"] boolValue];
            
            dispatch_semaphore_wait(downloadSemaphore, DISPATCH_TIME_FOREVER);
            NSString *downloadUrl = [self getDownloadURLForProject:projID file:fileID];
            if (!downloadUrl && required) {
                NSLog(@"[CurseForgeAPI] Could not obtain download URL for project %@, file %@. Aborting subfile downloads.", projID, fileID);
                dispatch_semaphore_signal(downloadSemaphore);
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self fallbackOpenBrowserWithURL:self.fallbackZipUrl];
                });
                return;
            } else if (!downloadUrl) {
                dispatch_semaphore_signal(downloadSemaphore);
                continue;
            }
            
            NSString *fileName = downloadUrl.lastPathComponent;
            NSString *destModPath = [self.pendingDestinationPath stringByAppendingPathComponent:[NSString stringWithFormat:@"mods/%@", fileName]];
            
            NSString *sha1 = [self getSha1ForProject:projID file:fileID];
            NSDictionary *userInfo = @{
                @"downloadUrl": downloadUrl,
                @"destPath": destModPath,
                @"sha1": (sha1 ?: @"")
            };
            [[NSNotificationCenter defaultCenter] postNotificationName:@"StartSubfileDownload" object:self userInfo:userInfo];
            
            dispatch_semaphore_signal(downloadSemaphore);
        }
        
        // After scheduling all subfile downloads, remove the modpack zip.
        [[NSFileManager defaultManager] removeItemAtPath:self.pendingPackagePath error:nil];
        self.pendingManifest = nil;
        self.pendingPackagePath = nil;
        self.pendingDestinationPath = nil;
    });
}

#pragma mark - Fallback Browser

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

#pragma mark - Downloader for Subfiles

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

@end
