#import "CurseForgeAPI.h"
#import "config.h"
#import "MinecraftResourceDownloadTask.h"
#import "PLProfiles.h"
#import "ModpackUtils.h"
#import "UnzipKit.h"
#import "AFNetworking.h"

#define kCurseForgeGameIDMinecraft 432
#define kCurseForgeClassIDModpack 4471
#define kCurseForgeClassIDMod 6
#define CURSEFORGE_PAGINATION_SIZE 50

@interface CurseForgeAPI ()
@property (nonatomic, copy) NSString *apiKey;
- (BOOL)verifyManifestFromDictionary:(NSDictionary *)manifest;
- (void)asyncExtractManifestFromPackage:(NSString *)packagePath
                             completion:(void (^)(NSDictionary *manifestDict, NSError *error))completion;
- (void)getEndpoint:(NSString *)endpoint
             params:(NSDictionary *)params
         completion:(void (^)(id result, NSError *error))completion;
- (void)getDownloadUrlForProject:(unsigned long long)projectID
                          fileID:(unsigned long long)fileID
                      completion:(void (^)(NSString *downloadUrl, NSError *error))completion;
/**
 * Helper method to handle fallback URL generation if the primary endpoint fails or returns invalid data.
 */
- (void)handleDownloadUrlFallbackForProject:(unsigned long long)projectID
                                     fileID:(unsigned long long)fileID
                                 completion:(void (^)(NSString *downloadUrl, NSError *error))completion;
@end

@implementation CurseForgeAPI {
    dispatch_queue_t _networkQueue;
}

#pragma mark - Initialization

- (instancetype)initWithAPIKey:(NSString *)apiKey {
    self = [super initWithURL:@"https://api.curseforge.com/v1"];
    if (self) {
        self.apiKey = apiKey;
        _networkQueue = dispatch_queue_create("com.curseforge.api.network", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

#pragma mark - Asynchronous GET Endpoint

- (void)getEndpoint:(NSString *)endpoint
             params:(NSDictionary *)params
         completion:(void (^)(id result, NSError *error))completion
{
    NSString *url = [self.baseURL stringByAppendingPathComponent:endpoint];
    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    
    NSString *key = self.apiKey;
    if (key.length == 0) {
        char *envKey = getenv("CURSEFORGE_API_KEY");
        if (envKey) {
            key = [NSString stringWithUTF8String:envKey];
        }
    }
    [manager.requestSerializer setValue:key forHTTPHeaderField:@"x-api-key"];
    
    [manager GET:url
      parameters:params
         headers:nil
        progress:nil
         success:^(NSURLSessionTask *task, id responseObject) {
             // Valid 2xx response; pass it to completion
             if (completion) completion(responseObject, nil);
         }
         failure:^(NSURLSessionTask *operation, NSError *error) {
             // HTTP failure, network error, or non-2xx status
             self.lastError = error;
             if (completion) completion(nil, error);
         }];
}

#pragma mark - Asynchronous Download URL Generation

- (void)getDownloadUrlForProject:(unsigned long long)projectID
                          fileID:(unsigned long long)fileID
                      completion:(void (^)(NSString *downloadUrl, NSError *error))completion
{
    NSString *endpoint = [NSString stringWithFormat:@"mods/%llu/files/%llu/download-url", projectID, fileID];
    __block int attempt = 0;
    __weak typeof(self) weakSelf = self;
    
    void (^attemptBlock)(void) = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            if (completion) {
                NSError *err = [NSError errorWithDomain:@"CurseForgeAPIErrorDomain"
                                                   code:-1
                                               userInfo:@{NSLocalizedDescriptionKey:
                                                          @"Internal error: self was deallocated"}];
                completion(nil, err);
            }
            return;
        }
        
        [strongSelf getEndpoint:endpoint params:nil completion:^(id response, NSError *error) {
            if (error) {
                // If the primary request fails, we might fallback
                attempt++;
                if (attempt < 2) {
                    // Retry once after 0.5s
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                                   strongSelf->_networkQueue, attemptBlock);
                } else {
                    // Move to the fallback approach
                    [strongSelf handleDownloadUrlFallbackForProject:projectID fileID:fileID completion:completion];
                }
                return;
            }
            
            // If there's no error, parse the response
            if (response && [response isKindOfClass:[NSDictionary class]]) {
                NSDictionary *dictResp = (NSDictionary *)response;
                id dataObj = dictResp[@"data"];
                if (dataObj && ![dataObj isKindOfClass:[NSNull class]]) {
                    NSString *url = [NSString stringWithFormat:@"%@", dataObj];
                    if (url.length > 0) {
                        if (completion) completion(url, nil);
                        return;
                    }
                }
            }
            
            // If "data" is empty or missing, fallback
            attempt++;
            if (attempt < 2) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                               strongSelf->_networkQueue, attemptBlock);
            } else {
                [strongSelf handleDownloadUrlFallbackForProject:projectID fileID:fileID completion:completion];
            }
        }];
    };
    
    attemptBlock();
}

- (void)handleDownloadUrlFallbackForProject:(unsigned long long)projectID
                                     fileID:(unsigned long long)fileID
                                 completion:(void (^)(NSString *downloadUrl, NSError *error))completion
{
    // 1) Build direct API fallback URL
    NSString *fallbackUrl = [NSString stringWithFormat:
        @"https://www.curseforge.com/api/v1/mods/%llu/files/%llu/download",
        projectID, fileID];
    if (self.apiKey && self.apiKey.length > 0) {
        fallbackUrl = [fallbackUrl stringByAppendingFormat:@"?apiKey=%@", self.apiKey];
    }
    
    // 2) Attempt media.forgecdn.net link from file metadata
    NSString *endpoint2 = [NSString stringWithFormat:@"mods/%llu/files/%llu", projectID, fileID];
    [self getEndpoint:endpoint2 params:nil completion:^(id fallbackResponse, NSError *error) {
        if (error) {
            NSLog(@"Fallback metadata request error: %@", error.localizedDescription);
            // We’ll pass fallbackUrl in case it’s valid
            if (completion) completion(fallbackUrl, nil);
            return;
        }
        
        NSLog(@"Fallback metadata response: %@", fallbackResponse);
        
        if ([fallbackResponse isKindOfClass:[NSDictionary class]]) {
            NSDictionary *respDict = (NSDictionary *)fallbackResponse;
            id dataObj = respDict[@"data"];
            if ([dataObj isKindOfClass:[NSDictionary class]]) {
                NSDictionary *modData = (NSDictionary *)dataObj;
                id idNumberObj = modData[@"id"];
                id fileNameObj = modData[@"fileName"];
                if ([idNumberObj isKindOfClass:[NSNumber class]] &&
                    [fileNameObj isKindOfClass:[NSString class]])
                {
                    NSNumber *idNumber = (NSNumber *)idNumberObj;
                    NSString *fileName = (NSString *)fileNameObj;
                    if (fileName.length > 0) {
                        unsigned long long idValue = [idNumber unsignedLongLongValue];
                        NSString *mediaLink = [NSString stringWithFormat:
                            @"https://media.forgecdn.net/files/%llu/%llu/%@",
                            idValue / 1000, idValue % 1000, fileName];
                        
                        if (mediaLink.length > 0) {
                            // Return the mediaLink
                            if (completion) completion(mediaLink, nil);
                            return;
                        }
                    }
                } else {
                    NSLog(@"Fallback 'data' keys have unexpected types: id=%@, fileName=%@",
                          idNumberObj, fileNameObj);
                }
            } else {
                NSLog(@"Fallback 'data' is not a dictionary: %@", dataObj);
            }
        } else {
            NSLog(@"Fallback response is not a dictionary: %@", fallbackResponse);
        }
        
        // If mediaLink build failed, use fallbackUrl or return an error
        if (fallbackUrl.length > 0) {
            if (completion) completion(fallbackUrl, nil);
        } else {
            NSError *err = [NSError errorWithDomain:@"CurseForgeAPIErrorDomain"
                                               code:-1002
                                           userInfo:@{NSLocalizedDescriptionKey:
                                                      @"Unable to obtain any valid download URL."}];
            if (completion) completion(nil, err);
        }
    }];
}

#pragma mark - Asynchronous Manifest Extraction (Disk-Based)

- (void)asyncExtractManifestFromPackage:(NSString *)packagePath
                             completion:(void (^)(NSDictionary *manifestDict, NSError *error))completion
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error = nil;
        UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
        if (!archive) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, error);
            });
            return;
        }
        NSData *manifestData = [archive extractDataFromFile:@"manifest.json" error:&error];
        if (!manifestData) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, error);
            });
            return;
        }
        // Write to disk
        NSString *tempDir = NSTemporaryDirectory();
        NSString *tempManifestPath = [tempDir stringByAppendingPathComponent:@"manifest.json"];
        BOOL writeSuccess = [manifestData writeToFile:tempManifestPath atomically:YES];
        if (!writeSuccess) {
            NSError *writeError = [NSError errorWithDomain:@"CurseForgeAPIErrorDomain"
                                                      code:-1
                                                  userInfo:@{NSLocalizedDescriptionKey:
                                                             @"Failed to write manifest to disk"}];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, writeError);
            });
            return;
        }
        // Read back from disk
        NSData *diskData = [NSData dataWithContentsOfFile:tempManifestPath options:0 error:&error];
        if (!diskData) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, error);
            });
            return;
        }
        NSDictionary *manifestDict = [NSJSONSerialization JSONObjectWithData:diskData
                                                                     options:0
                                                                       error:&error];
        [[NSFileManager defaultManager] removeItemAtPath:tempManifestPath error:nil];
        if (!manifestDict) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, error);
            });
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(manifestDict, nil);
        });
    });
}

#pragma mark - Asynchronous API Methods

- (void)searchModWithFilters:(NSDictionary *)searchFilters
         previousPageResult:(NSMutableArray *)prevResult
                 completion:(void (^ _Nonnull)(NSMutableArray * _Nullable results,
                                               NSError * _Nullable error))completion
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        int limit = CURSEFORGE_PAGINATION_SIZE;
        NSString *query = searchFilters[@"name"] ?: @"";
        NSMutableDictionary *params = [@{
            @"gameId": @(kCurseForgeGameIDMinecraft),
            @"classId": ([searchFilters[@"isModpack"] boolValue]
                         ? @(kCurseForgeClassIDModpack)
                         : @(kCurseForgeClassIDMod)),
            @"searchFilter": query,
            @"sortField": @(1),
            @"sortOrder": @"desc",
            @"pageSize": @(limit),
            @"index": @(prevResult.count)
        } mutableCopy];
        
        if (searchFilters[@"mcVersion"] && [searchFilters[@"mcVersion"] length] > 0) {
            params[@"gameVersion"] = searchFilters[@"mcVersion"];
        }
        
        [self getEndpoint:@"mods/search" params:params completion:^(id response, NSError *error) {
            if (!response) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(nil, self.lastError);
                });
                return;
            }
            
            NSMutableArray *result = prevResult ?: [NSMutableArray new];
            NSArray *data = response[@"data"];
            for (NSDictionary *mod in data) {
                id allow = mod[@"allowModDistribution"];
                if (allow && ![allow isKindOfClass:[NSNull class]] && ![allow boolValue]) {
                    continue;
                }
                BOOL isModpack = ([mod[@"classId"] integerValue] == kCurseForgeClassIDModpack);
                NSMutableDictionary *entry = [@{
                    @"apiSource": @(1),
                    @"isModpack": @(isModpack),
                    @"id": [NSString stringWithFormat:@"%@", mod[@"id"]],
                    @"title": (mod[@"name"] ? [NSString stringWithFormat:@"%@", mod[@"name"]] : @""),
                    @"description": (mod[@"summary"] ? [NSString stringWithFormat:@"%@", mod[@"summary"]] : @""),
                    @"imageUrl": (mod[@"logo"] ? [NSString stringWithFormat:@"%@", mod[@"logo"]] : @"")
                } mutableCopy];
                [result addObject:entry];
            }
            
            NSDictionary *pagination = response[@"pagination"];
            NSUInteger totalCount = [pagination[@"totalCount"] unsignedIntegerValue];
            self.reachedLastPage = (result.count >= totalCount);
            
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(result, nil);
            });
        }];
    });
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item
              completion:(void (^ _Nonnull)(NSError * _Nullable error))completion
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *modId = [NSString stringWithFormat:@"%@", item[@"id"]];
        [self getEndpoint:[NSString stringWithFormat:@"mods/%@/files", modId]
                   params:nil
               completion:^(id response, NSError *error) {
            if (!response) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(self.lastError);
                });
                return;
            }
            NSArray *files = response[@"data"];
            NSMutableArray *names = [NSMutableArray new];
            NSMutableArray *mcNames = [NSMutableArray new];
            NSMutableArray *urls = [NSMutableArray new];
            NSMutableArray *hashes = [NSMutableArray new];
            NSMutableArray *sizes = [NSMutableArray new];
            
            for (NSDictionary *file in files) {
                [names addObject:[NSString stringWithFormat:@"%@", file[@"fileName"] ?: @""]];
                
                id versions = file[@"gameVersion"] ?: file[@"gameVersionList"];
                NSString *gameVersion = @"";
                if ([versions isKindOfClass:[NSArray class]] && [versions count] > 0) {
                    gameVersion = [NSString stringWithFormat:@"%@", ((NSArray *)versions)[0]];
                } else if ([versions isKindOfClass:[NSString class]]) {
                    gameVersion = [NSString stringWithFormat:@"%@", versions];
                }
                [mcNames addObject:gameVersion];
                
                [urls addObject:[NSString stringWithFormat:@"%@", file[@"downloadUrl"] ?: @""]];
                
                NSNumber *sizeNumber = nil;
                id fileLength = file[@"fileLength"];
                if ([fileLength isKindOfClass:[NSNumber class]]) {
                    sizeNumber = fileLength;
                } else if ([fileLength isKindOfClass:[NSString class]]) {
                    sizeNumber = @([fileLength unsignedLongLongValue]);
                } else {
                    sizeNumber = @(0);
                }
                [sizes addObject:sizeNumber];
                
                NSString *sha1 = @"";
                NSArray *hashesArray = file[@"hashes"];
                for (NSDictionary *hashDict in hashesArray) {
                    if ([[NSString stringWithFormat:@"%@", hashDict[@"algo"]] isEqualToString:@"SHA1"]) {
                        sha1 = [NSString stringWithFormat:@"%@", hashDict[@"value"]];
                        break;
                    }
                }
                [hashes addObject:sha1];
            }
            
            item[@"versionNames"] = names;
            item[@"mcVersionNames"] = mcNames;
            item[@"versionUrls"] = urls;
            item[@"versionHashes"] = hashes;
            item[@"versionSizes"] = sizes;
            item[@"versionDetailsLoaded"] = @(YES);
            
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil);
            });
        }];
    });
}

- (void)installModpackFromDetail:(NSDictionary *)modDetail
                         atIndex:(NSUInteger)selectedVersion
                      completion:(void (^ _Nonnull)(NSError * _Nullable error))completion
{
    NSArray *versionNames = modDetail[@"versionNames"];
    if (selectedVersion >= versionNames.count) {
        if (completion) {
            NSError *error = [NSError errorWithDomain:@"CurseForgeAPIErrorDomain"
                                                 code:100
                                             userInfo:@{NSLocalizedDescriptionKey: @"Selected version index is out of bounds."}];
            completion(error);
        }
        return;
    }
    [super installModpackFromDetail:modDetail atIndex:selectedVersion];
    if (completion) {
        completion(nil);
    }
}

#pragma mark - New Downloader Function (Asynchronous)

- (void)downloader:(MinecraftResourceDownloadTask *)downloader
submitDownloadTasksFromPackage:(NSString *)packagePath
            toPath:(NSString *)destPath
{
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            NSError *error = nil;
            UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
            if (!archive) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSLog(@"Archive initialization failed: %@", error.localizedDescription);
                    [downloader finishDownloadWithErrorString:error.localizedDescription];
                });
                return;
            }
            
            [weakSelf asyncExtractManifestFromPackage:packagePath
                                           completion:^(NSDictionary *manifestDict, NSError *error) {
                if (error || !manifestDict) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        NSLog(@"Manifest extraction failed: %@", error.localizedDescription);
                        [downloader finishDownloadWithErrorString:
                         [NSString stringWithFormat:@"Failed to extract manifest.json: %@", error.localizedDescription]];
                    });
                    return;
                }
                
                if (![weakSelf verifyManifestFromDictionary:manifestDict]) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        NSLog(@"Manifest verification failed");
                        [downloader finishDownloadWithErrorString:@"Manifest verification failed"];
                    });
                    return;
                }
                
                NSArray *allFiles = manifestDict[@"files"];
                NSMutableArray *files = [NSMutableArray new];
                NSMutableSet *uniqueKeys = [NSMutableSet new];
                for (NSDictionary *fileEntry in allFiles) {
                    NSString *uniqueKey = [NSString stringWithFormat:@"%@-%@", fileEntry[@"projectID"], fileEntry[@"fileID"]];
                    if (![uniqueKeys containsObject:uniqueKey]) {
                        [uniqueKeys addObject:uniqueKey];
                        [files addObject:fileEntry];
                    }
                }
                
                NSString *modpackName = manifestDict[@"name"] ?: @"Unknown Modpack";
                
                // Pre-calculate total download tasks
                dispatch_async(dispatch_get_main_queue(), ^{
                    downloader.progress.totalUnitCount = files.count;
                });
                
                // Process each file
                dispatch_group_t group = dispatch_group_create();
                for (NSDictionary *fileEntry in files) {
                    dispatch_group_enter(group);
                    NSNumber *projectID = fileEntry[@"projectID"];
                    NSNumber *fileID = fileEntry[@"fileID"];
                    BOOL required = [fileEntry[@"required"] boolValue];
                    
                    [weakSelf getDownloadUrlForProject:[projectID unsignedLongLongValue]
                                                 fileID:[fileID unsignedLongLongValue]
                                             completion:^(NSString *url, NSError *error) {
                        if (!url && required) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                NSString *modName = fileEntry[@"fileName"];
                                if (!modName || modName.length == 0) {
                                    modName = [NSString stringWithFormat:@"Project %@ File %@", projectID, fileID];
                                }
                                NSLog(@"Failed to obtain URL for %@ in modpack %@", modName, modpackName);
                                [downloader finishDownloadWithErrorString:
                                 [NSString stringWithFormat:@"Failed to obtain download URL for modpack '%@' and mod '%@'",
                                  modpackName, modName]];
                            });
                            dispatch_group_leave(group);
                            return;
                        } else if (!url) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                // If not required, increment the completed count
                                downloader.progress.completedUnitCount++;
                            });
                            dispatch_group_leave(group);
                            return;
                        }
                        
                        // Build destination file path
                        NSString *relativePath = fileEntry[@"path"];
                        if (!relativePath || relativePath.length == 0) {
                            relativePath = fileEntry[@"fileName"];
                            if (!relativePath || relativePath.length == 0) {
                                NSURL *downloadURL = [NSURL URLWithString:url];
                                relativePath = downloadURL.lastPathComponent;
                                if (!relativePath || relativePath.length == 0) {
                                    relativePath = [NSString stringWithFormat:@"%@.jar", fileID];
                                }
                            }
                        }
                        NSString *destinationPath = [destPath stringByAppendingPathComponent:relativePath];
                        
                        NSUInteger fileSize = 1;
                        if (fileEntry[@"fileLength"] &&
                            [fileEntry[@"fileLength"] respondsToSelector:@selector(unsignedIntegerValue)]) {
                            fileSize = [fileEntry[@"fileLength"] unsignedIntegerValue];
                            if (fileSize == 0) { fileSize = 1; }
                        }
                        
                        @try {
                            NSURLSessionDownloadTask *task = [downloader createDownloadTask:url
                                                                                       size:fileSize
                                                                                        sha:nil
                                                                                     altName:nil
                                                                                       toPath:destinationPath];
                            if (task) {
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    [downloader.fileList addObject:relativePath];
                                    NSLog(@"Starting download for %@", relativePath);
                                    [task resume];
                                });
                            } else {
                                dispatch_async(dispatch_get_main_queue(), ^{
                                    if (!downloader.progress.cancelled) {
                                        downloader.progress.completedUnitCount++;
                                    }
                                });
                            }
                        } @catch (NSException *exception) {
                            NSLog(@"Exception creating/resuming download task for %@: %@",
                                  relativePath, exception);
                        }
                        dispatch_group_leave(group);
                    }];
                }
                
                // After all metadata is retrieved, process overrides
                dispatch_group_notify(group,
                                      dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    NSError *archiveError = nil;
                    UZKArchive *archive2 = [[UZKArchive alloc] initWithPath:packagePath error:&archiveError];
                    if (!archive2) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            NSLog(@"Failed to reopen archive: %@", archiveError.localizedDescription);
                            [downloader finishDownloadWithErrorString:
                             [NSString stringWithFormat:@"Failed to reopen archive: %@", archiveError.localizedDescription]];
                        });
                        return;
                    }
                    
                    NSError *extractError = nil;
                    [ModpackUtils archive:archive2
                        extractDirectory:@"overrides"
                                   toPath:destPath
                                    error:&extractError];
                    if (extractError) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            NSLog(@"Failed to extract overrides: %@", extractError.localizedDescription);
                            [downloader finishDownloadWithErrorString:
                             [NSString stringWithFormat:@"Failed to extract overrides: %@", extractError.localizedDescription]];
                        });
                        return;
                    }
                    
                    [[NSFileManager defaultManager] removeItemAtPath:packagePath error:nil];
                    
                    // Dependencies if present
                    NSDictionary<NSString *, NSString *> *depInfo =
                        [ModpackUtils infoForDependencies:manifestDict[@"dependencies"]];
                    if (depInfo[@"json"]) {
                        NSString *jsonPath = [NSString stringWithFormat:
                                              @"%1$s/versions/%2$@/%2$@.json",
                                              getenv("POJAV_GAME_DIR"), depInfo[@"id"]];
                        NSURLSessionDownloadTask *depTask =
                            [downloader createDownloadTask:depInfo[@"json"]
                                                       size:1
                                                        sha:nil
                                                     altName:nil
                                                       toPath:jsonPath];
                        if (depTask) {
                            dispatch_async(dispatch_get_main_queue(), ^{
                                NSLog(@"Starting dependency download");
                                [depTask resume];
                            });
                        }
                    }
                    
                    // Version and profile info
                    NSDictionary *minecraft = manifestDict[@"minecraft"];
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
                            if (!primaryModLoader) {
                                primaryModLoader = modLoaders[0];
                            }
                            modLoaderId = primaryModLoader[@"id"] ?: @"";
                            NSRange dashRange = [modLoaderId rangeOfString:@"-"];
                            if (dashRange.location != NSNotFound) {
                                NSString *loaderName = [modLoaderId substringToIndex:dashRange.location];
                                NSString *loaderVer = [modLoaderId substringFromIndex:(dashRange.location + 1)];
                                if ([loaderName isEqualToString:@"forge"]) {
                                    modLoaderVersion = [NSString stringWithFormat:@"forge-%@", loaderVer];
                                    modLoaderId = @"forge";
                                } else if ([loaderName isEqualToString:@"fabric"]) {
                                    modLoaderVersion = [NSString stringWithFormat:@"fabric-loader-%@-%@", loaderVer, vanillaVersion];
                                    modLoaderId = @"fabric";
                                } else {
                                    modLoaderVersion = loaderVer;
                                }
                            } else {
                                modLoaderVersion = modLoaderId;
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
                    
                    NSString *profileName = manifestDict[@"name"];
                    if (profileName) {
                        NSDictionary *profileInfo = @{
                            @"gameDir": [NSString stringWithFormat:@"./custom_gamedir/%@", destPath.lastPathComponent],
                            @"name": profileName,
                            @"lastVersionId": finalVersionString,
                            @"icon": @""
                        };
                        dispatch_async(dispatch_get_main_queue(), ^{
                            NSLog(@"Setting profile: %@", profileName);
                            PLProfiles.current.profiles[profileName] = [profileInfo mutableCopy];
                            PLProfiles.current.selectedProfileName = profileName;
                        });
                    }
                });
            }];
        }
    });
}

#pragma mark - Helper Methods

- (BOOL)verifyManifestFromDictionary:(NSDictionary *)manifest {
    if (![manifest[@"manifestType"] isEqualToString:@"minecraftModpack"]) return NO;
    if ([manifest[@"manifestVersion"] integerValue] != 1) return NO;
    if (!manifest[@"minecraft"]) return NO;
    NSDictionary *minecraft = manifest[@"minecraft"];
    if (!minecraft[@"version"]) return NO;
    if (!minecraft[@"modLoaders"]) return NO;
    NSArray *modLoaders = minecraft[@"modLoaders"];
    if (![modLoaders isKindOfClass:[NSArray class]] || modLoaders.count < 1) return NO;
    return YES;
}

@end
