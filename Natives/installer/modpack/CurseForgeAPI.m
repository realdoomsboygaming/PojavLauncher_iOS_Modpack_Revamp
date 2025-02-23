#import "CurseForgeAPI.h"
#import "config.h"
#import "MinecraftResourceDownloadTask.h"
#import "PLProfiles.h"
#import "ModpackUtils.h"
#import "UnzipKit.h"
#import "AFNetworking.h"

// Minimal helper: save a JSON dictionary to a file. Returns nil on success or an NSError on failure.
static NSError *saveJSONToFile(NSDictionary *jsonDict, NSString *filePath) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:jsonDict options:0 error:&error];
    if (!data) return error;
    BOOL success = [data writeToFile:filePath options:NSDataWritingAtomic error:&error];
    if (!success) return error;
    return nil;
}

#define kCurseForgeGameIDMinecraft 432
#define kCurseForgeClassIDModpack 4471
#define kCurseForgeClassIDMod 6
#define CURSEFORGE_PAGINATION_SIZE 50

@interface CurseForgeAPI ()
// API key for authentication.
@property (nonatomic, copy) NSString *apiKey;
// Private helper methods.
- (BOOL)verifyManifestFromDictionary:(NSDictionary *)manifest;
- (void)asyncExtractManifestFromPackage:(NSString *)packagePath
                             completion:(void (^)(NSDictionary *manifestDict, NSError *error))completion;
- (void)getEndpoint:(NSString *)endpoint
             params:(NSDictionary *)params
         completion:(void (^)(id result, NSError *error))completion;
- (void)handleDownloadUrlFallbackForProject:(unsigned long long)projectID
                                     fileID:(unsigned long long)fileID
                                 completion:(void (^)(NSString *downloadUrl, NSError *error))completion;
- (void)autoInstallForge:(NSString *)vanillaVer loaderVersion:(NSString *)forgeVer;
- (void)autoInstallFabricWithFullString:(NSString *)fabricString;
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

#pragma mark - GET Endpoint (Asynchronous)

- (void)getEndpoint:(NSString *)endpoint
             params:(NSDictionary *)params
         completion:(void (^)(id result, NSError *error))completion {
    NSString *url = [self.baseURL stringByAppendingPathComponent:endpoint];
    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    
    // Use API key if available.
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
             if (completion) completion(responseObject, nil);
         }
         failure:^(NSURLSessionTask *operation, NSError *error) {
             self.lastError = error;
             if (completion) completion(nil, error);
         }];
}

#pragma mark - Download URL Generation with Fallback

- (void)getDownloadUrlForProject:(unsigned long long)projectID
                          fileID:(unsigned long long)fileID
                      completion:(void (^)(NSString *downloadUrl, NSError *error))completion {
    NSString *endpoint = [NSString stringWithFormat:@"mods/%llu/files/%llu/download-url", projectID, fileID];
    __block int attempt = 0;
    
    __weak typeof(self) weakSelf = self;
    __block void (^attemptBlock)(void) = nil;
    __weak void (^weakAttemptBlock)(void) = nil;
    
    attemptBlock = [^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            if (completion) {
                NSError *err = [NSError errorWithDomain:@"CurseForgeAPIErrorDomain"
                                                   code:-1
                                               userInfo:@{NSLocalizedDescriptionKey: @"Internal error (self was deallocated)."}];
                completion(nil, err);
            }
            return;
        }
        [strongSelf getEndpoint:endpoint params:nil completion:^(id response, NSError *error) {
            if (response && response[@"data"] && ![response[@"data"] isKindOfClass:[NSNull class]]) {
                NSString *urlString = [NSString stringWithFormat:@"%@", response[@"data"]];
                if (completion) completion(urlString, nil);
            } else {
                attempt++;
                if (attempt < 2) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                                   strongSelf->_networkQueue, ^{
                        __strong typeof(weakAttemptBlock) innerBlock = weakAttemptBlock;
                        if (innerBlock) {
                            innerBlock();
                        }
                    });
                } else {
                    [strongSelf handleDownloadUrlFallbackForProject:projectID fileID:fileID completion:completion];
                }
            }
        }];
    } copy];
    
    weakAttemptBlock = attemptBlock;
    attemptBlock();
}

- (void)handleDownloadUrlFallbackForProject:(unsigned long long)projectID
                                     fileID:(unsigned long long)fileID
                                 completion:(void (^)(NSString *downloadUrl, NSError *error))completion {
    // Build direct fallback URL.
    NSString *fallbackUrl = [NSString stringWithFormat:
        @"https://www.curseforge.com/api/v1/mods/%llu/files/%llu/download", projectID, fileID];
    if (self.apiKey && self.apiKey.length > 0) {
        fallbackUrl = [fallbackUrl stringByAppendingFormat:@"?apiKey=%@", self.apiKey];
    }
    
    // Attempt to build a media.forgecdn.net link from metadata.
    NSString *endpoint2 = [NSString stringWithFormat:@"mods/%llu/files/%llu", projectID, fileID];
    [self getEndpoint:endpoint2 params:nil completion:^(id fallbackResponse, NSError *error2) {
        NSLog(@"Fallback response: %@", fallbackResponse);
        if ([fallbackResponse isKindOfClass:[NSDictionary class]]) {
            NSDictionary *respDict = (NSDictionary *)fallbackResponse;
            id dataObj = respDict[@"data"];
            if ([dataObj isKindOfClass:[NSDictionary class]]) {
                NSDictionary *modData = (NSDictionary *)dataObj;
                id idNumberObj = modData[@"id"];
                id fileNameObj = modData[@"fileName"];
                if ([idNumberObj isKindOfClass:[NSNumber class]] &&
                    [fileNameObj isKindOfClass:[NSString class]]) {
                    NSNumber *idNumber = (NSNumber *)idNumberObj;
                    NSString *fileName = (NSString *)fileNameObj;
                    if (fileName.length > 0) {
                        unsigned long long idValue = [idNumber unsignedLongLongValue];
                        NSString *mediaLink = [NSString stringWithFormat:
                            @"https://media.forgecdn.net/files/%llu/%llu/%@",
                            idValue / 1000, idValue % 1000, fileName];
                        if (mediaLink.length > 0) {
                            if (completion) completion(mediaLink, nil);
                            return;
                        }
                    }
                } else {
                    NSLog(@"Fallback 'data' keys have unexpected types: id=%@, fileName=%@", idNumberObj, fileNameObj);
                }
            } else {
                NSLog(@"Fallback response 'data' is not a dictionary: %@", dataObj);
            }
        } else {
            NSLog(@"Fallback response is not a dictionary: %@", fallbackResponse);
        }
        
        if (fallbackUrl.length > 0) {
            if (completion) completion(fallbackUrl, nil);
        } else {
            NSError *err = [NSError errorWithDomain:@"CurseForgeAPIErrorDomain"
                                               code:-1002
                                           userInfo:@{NSLocalizedDescriptionKey: @"Unable to obtain any valid download URL."}];
            if (completion) completion(nil, err);
        }
    }];
}

#pragma mark - Manifest Extraction

- (void)asyncExtractManifestFromPackage:(NSString *)packagePath
                             completion:(void (^)(NSDictionary *manifestDict, NSError *error))completion {
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
        NSString *tempDir = NSTemporaryDirectory();
        NSString *tempManifestPath = [tempDir stringByAppendingPathComponent:@"manifest.json"];
        BOOL wroteFile = [manifestData writeToFile:tempManifestPath atomically:YES];
        if (!wroteFile) {
            NSError *writeError = [NSError errorWithDomain:@"CurseForgeAPIErrorDomain"
                                                      code:-1
                                                  userInfo:@{NSLocalizedDescriptionKey: @"Failed to write manifest to disk"}];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, writeError);
            });
            return;
        }
        NSData *diskData = [NSData dataWithContentsOfFile:tempManifestPath options:0 error:&error];
        [[NSFileManager defaultManager] removeItemAtPath:tempManifestPath error:nil];
        if (!diskData) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, error);
            });
            return;
        }
        NSDictionary *manifestDict = [NSJSONSerialization JSONObjectWithData:diskData options:0 error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(manifestDict, error);
        });
    });
}

#pragma mark - Searching, Loading Details, Installing Modpacks

- (void)searchModWithFilters:(NSDictionary *)searchFilters
         previousPageResult:(NSMutableArray *)prevResult
                 completion:(void (^ _Nonnull)(NSMutableArray *results, NSError *error))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        int limit = CURSEFORGE_PAGINATION_SIZE;
        NSString *query = searchFilters[@"name"] ?: @"";
        NSMutableDictionary *params = [@{
            @"gameId": @(kCurseForgeGameIDMinecraft),
            @"classId": ([searchFilters[@"isModpack"] boolValue] ? @(kCurseForgeClassIDModpack) : @(kCurseForgeClassIDMod)),
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
                    @"title": (mod[@"name"] ?: @""),
                    @"description": (mod[@"summary"] ?: @""),
                    @"imageUrl": (mod[@"logo"] ?: @"")
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
              completion:(void (^ _Nonnull)(NSError *error))completion {
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
                      completion:(void (^ _Nonnull)(NSError *error))completion {
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

#pragma mark - Submit Download Tasks from Modpack Package

- (void)downloader:(MinecraftResourceDownloadTask *)downloader
submitDownloadTasksFromPackage:(NSString *)packagePath
            toPath:(NSString *)destPath {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            NSError *err = nil;
            UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&err];
            if (!archive) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSLog(@"Archive initialization failed: %@", err.localizedDescription);
                    [downloader finishDownloadWithErrorString:err.localizedDescription];
                });
                return;
            }
            
            // Extract all files into destPath by iterating over each file in the archive.
            __block BOOL extractSuccess = YES;
            [archive performOnFilesInArchive:^(UZKFileInfo *fileInfo, BOOL *stop) {
                NSString *destItemPath = [destPath stringByAppendingPathComponent:fileInfo.filename];
                if (fileInfo.isDirectory) {
                    [[NSFileManager defaultManager] createDirectoryAtPath:destItemPath withIntermediateDirectories:YES attributes:nil error:nil];
                } else {
                    NSString *destDirPath = [destItemPath stringByDeletingLastPathComponent];
                    BOOL createdDir = [[NSFileManager defaultManager] createDirectoryAtPath:destDirPath withIntermediateDirectories:YES attributes:nil error:nil];
                    if (!createdDir) {
                        *stop = YES;
                        extractSuccess = NO;
                        return;
                    }
                    NSData *data = [archive extractData:fileInfo error:&err];
                    if (!data) {
                        *stop = YES;
                        extractSuccess = NO;
                        return;
                    }
                    BOOL written = [data writeToFile:destItemPath options:NSDataWritingAtomic error:&err];
                    if (!written) {
                        *stop = YES;
                        extractSuccess = NO;
                        return;
                    }
                }
            } error:&err];
            
            if (!extractSuccess) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSLog(@"Failed to extract archive: %@", err.localizedDescription);
                    [downloader finishDownloadWithErrorString:
                     [NSString stringWithFormat:@"Failed to extract modpack archive: %@", err.localizedDescription]];
                });
                return;
            }
            
            // Now load the manifest from the extracted files.
            NSString *manifestPath = [destPath stringByAppendingPathComponent:@"manifest.json"];
            NSData *manifestData = [NSData dataWithContentsOfFile:manifestPath];
            if (!manifestData) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [downloader finishDownloadWithErrorString:@"Manifest file not found in extracted files."];
                });
                return;
            }
            
            NSError *jsonError = nil;
            NSDictionary *manifestDict = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:&jsonError];
            if (!manifestDict || jsonError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [downloader finishDownloadWithErrorString:
                     [NSString stringWithFormat:@"Failed to parse manifest.json: %@", jsonError.localizedDescription]];
                });
                return;
            }
            
            // Process dependencies.
            NSDictionary<NSString *, NSString *> *depInfo =
                [ModpackUtils infoForDependencies:manifestDict[@"dependencies"]];
            if (depInfo[@"json"]) {
                NSString *jsonPath = [NSString stringWithFormat:@"%@/versions/%@/%@.json",
                                      [NSString stringWithUTF8String:getenv("POJAV_GAME_DIR")],
                                      depInfo[@"id"],
                                      depInfo[@"id"]];
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
            
            // Process the "minecraft" block to determine loader version.
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
            
            // Create a new profile (gameDir set to "./<destPath.lastPathComponent>")
            NSString *profileName = manifestDict[@"name"] ?: @"Unknown Modpack";
            if (profileName.length > 0) {
                NSDictionary *profileInfo = @{
                    @"gameDir": [NSString stringWithFormat:@"./%@", destPath.lastPathComponent],
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
            
            // Auto-install the loader (Forge or Fabric).
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([modLoaderId isEqualToString:@"forge"]) {
                    [weakSelf autoInstallForge:vanillaVersion loaderVersion:modLoaderVersion];
                } else if ([modLoaderId isEqualToString:@"fabric"]) {
                    [weakSelf autoInstallFabricWithFullString:finalVersionString];
                } else {
                    NSLog(@"Auto-install: Unrecognized loader: %@", modLoaderId);
                }
            });
            
            // Remove the modpack package now that everything is extracted.
            [[NSFileManager defaultManager] removeItemAtPath:packagePath error:nil];
        }
    });
}

#pragma mark - Helper: Auto-install Loader

- (void)autoInstallForge:(NSString *)vanillaVer loaderVersion:(NSString *)forgeVer {
    if (!vanillaVer.length || !forgeVer.length) {
        NSLog(@"autoInstallForge: Missing version information.");
        return;
    }
    // Build final ID (e.g., "1.19.2-forge-43.1.1")
    NSString *finalId = [NSString stringWithFormat:@"%@-forge-%@", vanillaVer, forgeVer];
    NSString *jsonPath = [NSString stringWithFormat:@"%@/versions/%@/%@.json", [NSString stringWithUTF8String:getenv("POJAV_GAME_DIR")], finalId, finalId];
    
    [[NSFileManager defaultManager] createDirectoryAtPath:jsonPath.stringByDeletingLastPathComponent
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    NSDictionary *forgeDict = @{
        @"id": finalId,
        @"type": @"custom",
        @"minecraft": vanillaVer,
        @"loader": @"forge",
        @"loaderVersion": forgeVer
    };
    NSError *writeErr = saveJSONToFile(forgeDict, jsonPath);
    if (writeErr) {
        NSLog(@"autoInstallForge: Error writing JSON: %@", writeErr);
    } else {
        NSLog(@"autoInstallForge: Successfully wrote Forge JSON at %@", jsonPath);
    }
}

- (void)autoInstallFabricWithFullString:(NSString *)fabricString {
    if (!fabricString.length) {
        NSLog(@"autoInstallFabric: Missing fabric version string.");
        return;
    }
    NSString *jsonPath = [NSString stringWithFormat:@"%@/versions/%@/%@.json", [NSString stringWithUTF8String:getenv("POJAV_GAME_DIR")], fabricString, fabricString];
    [[NSFileManager defaultManager] createDirectoryAtPath:jsonPath.stringByDeletingLastPathComponent
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    NSDictionary *fabricDict = @{
        @"id": fabricString,
        @"type": @"custom",
        @"loader": @"fabric",
        @"loaderVersion": fabricString
    };
    NSError *writeErr = saveJSONToFile(fabricDict, jsonPath);
    if (writeErr) {
        NSLog(@"autoInstallFabric: Error writing JSON: %@", writeErr);
    } else {
        NSLog(@"autoInstallFabric: Successfully wrote Fabric JSON at %@", jsonPath);
    }
}

#pragma mark - Manifest Verification

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
