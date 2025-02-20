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
// Pending properties to hold manifest and download info until the user taps "Play"
@property (nonatomic, strong, nullable) NSDictionary *pendingManifest;
@property (nonatomic, strong, nullable) NSString *pendingPackagePath;
@property (nonatomic, strong, nullable) NSString *pendingDestinationPath;
@property (nonatomic, strong, nullable) NSDictionary *pendingModpackDetail;
@property (nonatomic, assign) NSInteger pendingModpackIndex;
@end

@implementation CurseForgeAPI

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

#pragma mark - Asynchronous Networking

- (void)getEndpoint:(NSString *)endpoint
             params:(NSDictionary *)params
         completion:(void(^)(id _Nullable result, NSError * _Nullable error))completion {
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
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                                 completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, error);
            });
        } else if (data) {
            NSError *jsonErr = nil;
            id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(parsed, jsonErr);
            });
        }
    }];
    [task resume];
}

#pragma mark - Search Mods/Modpacks

- (void)searchModWithFilters:(NSDictionary<NSString *, id> *)searchFilters
         previousPageResult:(NSMutableArray * _Nullable)previousResults
                 completion:(void(^)(NSMutableArray * _Nullable results, NSError * _Nullable error))completion {
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
    
    [self getEndpoint:@"mods/search" params:params completion:^(id result, NSError *error) {
        if (error || !result) {
            self.lastError = error;
            if (completion) completion(nil, error);
            return;
        }
        
        NSMutableArray *resultsArray = previousResults ?: [NSMutableArray array];
        NSArray *dataArray = result[@"data"];
        if (![dataArray isKindOfClass:[NSArray class]]) {
            if (completion) {
                completion(nil, [NSError errorWithDomain:@"CurseForgeAPI" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Malformed response"}]);
            }
            return;
        }
        
        for (NSDictionary *modDict in dataArray) {
            if (![modDict isKindOfClass:[NSDictionary class]]) continue;
            
            id allowDist = modDict[@"allowModDistribution"];
            if ([allowDist isKindOfClass:[NSNumber class]] && ![allowDist boolValue]) {
                NSLog(@"[CurseForgeAPI] Skipping modpack because allowModDistribution=false");
                continue;
            }
            
            NSString *modId = @"";
            id modIdValue = modDict[@"id"];
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
            [resultsArray addObject:item];
        }
        
        NSUInteger totalCount = 0;
        NSDictionary *paginationInfo = result[@"pagination"];
        if ([paginationInfo isKindOfClass:[NSDictionary class]]) {
            NSNumber *tc = paginationInfo[@"totalCount"];
            if ([tc isKindOfClass:[NSNumber class]]) {
                totalCount = tc.unsignedIntegerValue;
            }
        }
        
        self.previousOffset += [dataArray count];
        if ([dataArray count] < limit || [resultsArray count] >= totalCount) {
            self.reachedLastPage = YES;
        }
        self.lastSearchTerm = searchName;
        if (completion) completion(resultsArray, nil);
    }];
}

#pragma mark - Load Details

- (void)loadDetailsOfMod:(NSMutableDictionary *)item completion:(void(^)(NSError * _Nullable error))completion {
    NSString *modId = item[@"id"];
    if (modId.length == 0) {
        if (completion) {
            completion([NSError errorWithDomain:@"CurseForgeAPI" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid mod ID"}]);
        }
        return;
    }
    
    __block NSMutableArray *allFiles = [NSMutableArray array];
    __block NSInteger pageOffset = 0;
    __block BOOL endReached = NO;
    
    void (^loadPage)(void);
    __weak typeof(self) weakSelf = self;
    loadPage = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        NSDictionary *params = @{@"index": @(pageOffset), @"pageSize": @(50)};
        NSString *endpoint = [NSString stringWithFormat:@"mods/%@/files", modId];
        [strongSelf getEndpoint:endpoint params:params completion:^(id result, NSError *error) {
            if (error || !result) {
                if (completion) completion(error);
                return;
            }
            NSArray *data = result[@"data"];
            if (![data isKindOfClass:[NSArray class]]) {
                if (completion) {
                    completion([NSError errorWithDomain:@"CurseForgeAPI" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Malformed file data"}]);
                }
                return;
            }
            int addedCount = 0;
            for (NSDictionary *fileInfo in data) {
                if (![fileInfo isKindOfClass:[NSDictionary class]]) continue;
                if ([fileInfo[@"isServerPack"] boolValue]) continue;
                [allFiles addObject:fileInfo];
                addedCount++;
            }
            if ([data count] < 50) {
                endReached = YES;
            } else {
                pageOffset += [data count];
            }
            if (!endReached && addedCount == 0 && [data count] == 50) {
                endReached = YES;
            }
            if (!endReached) {
                loadPage();
            } else {
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
                    
                    NSString *sha1 = [strongSelf getSha1FromFileDict:fileDict];
                    [hashes addObject:(sha1 ?: @"")];
                }
                item[@"versionNames"] = versionNames;
                item[@"mcVersionNames"] = mcVersions;
                item[@"versionUrls"] = versionUrls;
                item[@"versionHashes"] = hashes;
                item[@"versionDetailsLoaded"] = @(YES);
                if (completion) completion(nil);
            }
        }];
    };
    
    loadPage();
}

#pragma mark - Install Modpack

- (void)installModpackFromDetail:(NSDictionary *)detail
                         atIndex:(NSInteger)index
                      completion:(void(^)(NSError * _Nullable error))completion {
    NSArray *urls = detail[@"versionUrls"];
    if (![urls isKindOfClass:[NSArray class]] || index < 0 || index >= urls.count) {
        NSLog(@"[CurseForgeAPI] No valid versionUrls or invalid index %ld", (long)index);
        if (completion) {
            completion([NSError errorWithDomain:@"CurseForgeAPI" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid version URLs or index"}]);
        }
        return;
    }
    NSString *zipUrlString = urls[index];
    if (zipUrlString.length == 0) {
        NSLog(@"[CurseForgeAPI] Empty zipUrl at index %ld", (long)index);
        if (completion) {
            completion([NSError errorWithDomain:@"CurseForgeAPI" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Empty zip URL"}]);
        }
        return;
    }
    NSURL *zipURL = [NSURL URLWithString:zipUrlString];
    if (!zipURL) {
        NSLog(@"[CurseForgeAPI] Could not parse zip URL: %@, falling back to browser", zipUrlString);
        [self fallbackOpenBrowserWithURL:zipUrlString];
        if (completion) {
            completion([NSError errorWithDomain:@"CurseForgeAPI" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid zip URL"}]);
        }
        return;
    }
    
    self.fallbackZipUrl = zipUrlString;
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
    __weak typeof(self) weakSelf = self;
    NSURLSessionDownloadTask *downloadTask = [session downloadTaskWithURL:zipURL completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (error) {
            NSLog(@"[CurseForgeAPI] Error downloading zip file: %@", error);
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf fallbackOpenBrowserWithURL:strongSelf.fallbackZipUrl];
                if (completion) completion(error);
            });
            return;
        }
        NSString *tempDir = NSTemporaryDirectory();
        NSString *destinationFilePath = [NSString stringWithFormat:@"%@/modpack_%@", tempDir, detail[@"id"]];
        [[NSFileManager defaultManager] removeItemAtPath:destinationFilePath error:nil];
        NSError *fileError = nil;
        BOOL success = [[NSFileManager defaultManager] moveItemAtPath:location.path toPath:destinationFilePath error:&fileError];
        if (!success) {
            NSLog(@"[CurseForgeAPI] Error moving zip file: %@", fileError);
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf fallbackOpenBrowserWithURL:strongSelf.fallbackZipUrl];
                if (completion) completion(fileError);
            });
            return;
        }
        NSString *customDestPath = [NSString stringWithFormat:@"%s/custom_gamedir/%@", getenv("POJAV_GAME_DIR"), detail[@"id"]];
        [strongSelf processManifestFromPackage:[NSURL fileURLWithPath:destinationFilePath] destinationPath:customDestPath downloader:nil completion:completion];
    }];
    [downloadTask resume];
}

- (void)processManifestFromPackage:(NSURL *)zipURL
                   destinationPath:(NSString *)destPath
                        downloader:(MinecraftResourceDownloadTask *)downloader
                        completion:(void(^)(NSError * _Nullable error))completion {
    NSString *packagePath = zipURL.path;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error;
        UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (downloader) {
                    [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to open modpack package: %@", error.localizedDescription]];
                }
                [self fallbackOpenBrowserWithURL:self.fallbackZipUrl];
                if (completion) completion(error);
            });
            return;
        }
        
        NSData *manifestData = [archive extractDataFromFile:@"manifest.json" error:&error];
        if (!manifestData || error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (downloader) {
                    [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to parse manifest.json: %@", error.localizedDescription]];
                }
                [self fallbackOpenBrowserWithURL:self.fallbackZipUrl];
                if (completion) completion(error);
            });
            return;
        }
        NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:&error];
        if (!manifest || error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (downloader) {
                    [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Invalid manifest.json: %@", error.localizedDescription]];
                }
                [self fallbackOpenBrowserWithURL:self.fallbackZipUrl];
                if (completion) completion(error);
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
                    [downloader finishDownloadWithErrorString:@"Manifest verification failed"];
                }
                [self fallbackOpenBrowserWithURL:self.fallbackZipUrl];
                if (completion) {
                    completion([NSError errorWithDomain:@"CurseForgeAPI" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Manifest verification failed"}]);
                }
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
            
            self.pendingManifest = manifest;
            self.pendingPackagePath = packagePath;
            self.pendingDestinationPath = destPath;
            
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ModpackReadyForPlay" object:self];
            if (completion) completion(nil);
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

#pragma mark - Helper Methods

- (NSString *)getDownloadURLForProject:(NSNumber *)projID file:(NSNumber *)fileID {
    if (!projID || !fileID) {
        NSLog(@"getDownloadURLForProject: Missing projID or fileID");
        return nil;
    }
    NSDictionary *params = @{@"gameId": @(kCurseForgeGameIDMinecraft)};
    NSString *endpoint = [NSString stringWithFormat:@"mods/%@/files/%@/download-url", projID, fileID];
    __block NSString *urlString = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [self getEndpoint:endpoint params:params completion:^(id result, NSError *error) {
        if ([result isKindOfClass:[NSDictionary class]]) {
            id dataVal = result[@"data"];
            if ([dataVal isKindOfClass:[NSString class]] && ((NSString *)dataVal).length > 0) {
                urlString = dataVal;
            }
        }
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    if (urlString) {
        return urlString;
    }
    
    endpoint = [NSString stringWithFormat:@"mods/%@/files/%@", projID, fileID];
    __block NSDictionary *fallback = nil;
    dispatch_semaphore_t sem2 = dispatch_semaphore_create(0);
    [self getEndpoint:endpoint params:params completion:^(id result, NSError *error) {
        if ([result isKindOfClass:[NSDictionary class]]) {
            fallback = result;
        }
        dispatch_semaphore_signal(sem2);
    }];
    dispatch_semaphore_wait(sem2, DISPATCH_TIME_FOREVER);
    NSDictionary *fallbackData = fallback[@"data"];
    if ([fallbackData isKindOfClass:[NSDictionary class]]) {
        NSNumber *fID = fallbackData[@"id"];
        NSString *fileName = fallbackData[@"fileName"];
        if (fID && fileName) {
            int numericId = [fID intValue];
            int prefix = numericId / 1000;
            int suffix = numericId % 1000;
            NSString *constructedURL = [NSString stringWithFormat:@"https://edge.forgecdn.net/files/%d/%03d/%@", prefix, suffix, fileName];
            return constructedURL;
        }
    }
    return nil;
}

- (NSString *)getSha1ForProject:(NSNumber *)projID file:(NSNumber *)fileID {
    if (!projID || !fileID) return nil;
    NSDictionary *params = @{@"gameId": @(kCurseForgeGameIDMinecraft)};
    NSString *endpoint = [NSString stringWithFormat:@"mods/%@/files/%@", projID, fileID];
    __block NSDictionary *resp = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [self getEndpoint:endpoint params:params completion:^(id result, NSError *error) {
        if ([result isKindOfClass:[NSDictionary class]]) {
            resp = result;
        }
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
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
