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
- (void)asyncExtractManifestFromPackage:(NSString *)packagePath completion:(void (^)(NSDictionary *manifestDict, NSError *error))completion;
- (NSString *)getDownloadUrlForProject:(unsigned long long)projectID fileID:(unsigned long long)fileID;
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

#pragma mark - Overridden GET Endpoint
- (id)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params {
    __block id result = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
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
    
    [manager GET:url parameters:params headers:nil progress:nil
         success:^(NSURLSessionTask *task, id obj) {
             result = obj;
             dispatch_semaphore_signal(semaphore);
         }
         failure:^(NSURLSessionTask *operation, NSError *error) {
             self.lastError = error;
             dispatch_semaphore_signal(semaphore);
         }];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    return result;
}

#pragma mark - Asynchronous API Methods

- (void)searchModWithFilters:(NSDictionary *)searchFilters
         previousPageResult:(NSMutableArray *)prevResult
                 completion:(void (^ _Nonnull)(NSMutableArray * _Nullable results, NSError * _Nullable error))completion {
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
        
        NSDictionary *response = [self getEndpoint:@"mods/search" params:params];
        if (!response) {
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(nil, self.lastError);
                });
            }
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
    });
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item
              completion:(void (^ _Nonnull)(NSError * _Nullable error))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *modId = [NSString stringWithFormat:@"%@", item[@"id"]];
        NSDictionary *response = [self getEndpoint:[NSString stringWithFormat:@"mods/%@/files", modId] params:nil];
        if (!response) {
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(self.lastError);
                });
            }
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
    });
}

- (void)installModpackFromDetail:(NSDictionary *)modDetail
                         atIndex:(NSUInteger)selectedVersion
                      completion:(void (^ _Nonnull)(NSError * _Nullable error))completion {
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

#pragma mark - Asynchronous Manifest Extraction (Disk-Based)

- (void)asyncExtractManifestFromPackage:(NSString *)packagePath completion:(void (^)(NSDictionary *manifestDict, NSError *error))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *error = nil;
        UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
        if (!archive) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, error);
            });
            return;
        }
        
        // Extract manifest.json directly to disk instead of into memory.
        NSString *tempDir = NSTemporaryDirectory();
        NSString *tempManifestPath = [tempDir stringByAppendingPathComponent:@"manifest.json"];
        BOOL success = [archive extractFile:@"manifest.json" toPath:tempManifestPath error:&error];
        if (!success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, error);
            });
            return;
        }
        
        // Now read the file from disk.
        NSData *manifestData = [NSData dataWithContentsOfFile:tempManifestPath options:0 error:&error];
        if (!manifestData) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, error);
            });
            return;
        }
        
        NSDictionary *manifestDict = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:&error];
        // Clean up the temporary file.
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

#pragma mark - New Downloader Function

- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            NSError *error = nil;
            UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
            if (!archive) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [downloader finishDownloadWithErrorString:error.localizedDescription];
                });
                return;
            }
            
            [weakSelf asyncExtractManifestFromPackage:packagePath completion:^(NSDictionary *manifestDict, NSError *error) {
                if (error || !manifestDict) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract manifest.json: %@", error.localizedDescription]];
                    });
                    return;
                }
                
                if (![weakSelf verifyManifestFromDictionary:manifestDict]) {
                    dispatch_async(dispatch_get_main_queue(), ^{
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
                NSUInteger totalDownloads = 0;
                
                for (NSDictionary *fileEntry in files) {
                    NSNumber *projectID = fileEntry[@"projectID"];
                    NSNumber *fileID = fileEntry[@"fileID"];
                    BOOL required = [fileEntry[@"required"] boolValue];
                    NSString *url = [weakSelf getDownloadUrlForProject:[projectID unsignedLongLongValue]
                                                                 fileID:[fileID unsignedLongLongValue]];
                    
                    if (url || !required) {
                        totalDownloads++;
                    }
                }
                
                downloader.progress.totalUnitCount = totalDownloads;
                
                for (NSDictionary *fileEntry in files) {
                    NSNumber *projectID = fileEntry[@"projectID"];
                    NSNumber *fileID = fileEntry[@"fileID"];
                    BOOL required = [fileEntry[@"required"] boolValue];
                    
                    NSString *url = [weakSelf getDownloadUrlForProject:[projectID unsignedLongLongValue]
                                                                 fileID:[fileID unsignedLongLongValue]];
                    
                    if (!url && required) {
                        NSString *modName = fileEntry[@"fileName"];
                        if (!modName || modName.length == 0) {
                            modName = [NSString stringWithFormat:@"Project %@ File %@", projectID, fileID];
                        }
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to obtain download URL for modpack '%@' and mod '%@'", modpackName, modName]];
                        });
                        return;
                    } else if (!url) {
                        downloader.progress.completedUnitCount++;
                        continue;
                    }
                    
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
                    
                    if (fileEntry[@"fileLength"] && [fileEntry[@"fileLength"] respondsToSelector:@selector(unsignedIntegerValue)]) {
                        fileSize = [fileEntry[@"fileLength"] unsignedIntegerValue];
                        if (fileSize == 0) { fileSize = 1; }
                    }
                    
                    NSURLSessionDownloadTask *task = [downloader createDownloadTask:url size:fileSize sha:nil altName:nil toPath:destinationPath];
                    if (task) {
                        [downloader.fileList addObject:relativePath];
                        [task resume];
                    } else if (!downloader.progress.cancelled) {
                        downloader.progress.completedUnitCount++;
                    } else {
                        return;
                    }
                }
                
                NSError *archiveError = nil;
                UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&archiveError];
                if (!archive) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to reopen archive: %@", archiveError.localizedDescription]];
                    });
                    return;
                }
                
                NSError *extractError = nil;
                [ModpackUtils archive:archive extractDirectory:@"overrides" toPath:destPath error:&extractError];
                if (extractError) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract overrides: %@", extractError.localizedDescription]];
                    });
                    return;
                }
                
                [[NSFileManager defaultManager] removeItemAtPath:packagePath error:nil];
                
                NSDictionary<NSString *, NSString *> *depInfo = [ModpackUtils infoForDependencies:manifestDict[@"dependencies"]];
                if (depInfo[@"json"]) {
                    NSString *jsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json",
                                          getenv("POJAV_GAME_DIR"), depInfo[@"id"]];
                    NSURLSessionDownloadTask *task = [downloader createDownloadTask:depInfo[@"json"] size:1 sha:nil altName:nil toPath:jsonPath];
                    [task resume];
                }
                
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
                    PLProfiles.current.profiles[profileName] = [profileInfo mutableCopy];
                    PLProfiles.current.selectedProfileName = profileName;
                }
            }];
        }
    });
}

#pragma mark - New Download URL Generation

- (NSString *)getDownloadUrlForProject:(unsigned long long)projectID fileID:(unsigned long long)fileID {
    __block NSString *downloadUrl = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    dispatch_async(_networkQueue, ^{
        // 1) Attempt the official endpoint with two attempts
        NSString *endpoint = [NSString stringWithFormat:@"mods/%llu/files/%llu/download-url", projectID, fileID];
        for (int attempt = 0; attempt < 2; attempt++) {
            NSDictionary *response = [self getEndpoint:endpoint params:nil];
            if (response && response[@"data"] && ![response[@"data"] isKindOfClass:[NSNull class]]) {
                downloadUrl = [NSString stringWithFormat:@"%@", response[@"data"]];
                dispatch_semaphore_signal(semaphore);
                return;
            }
            usleep(500000); // 0.5 second delay between attempts
        }
        
        // 2) Fallback: direct CurseForge API link
        downloadUrl = [NSString stringWithFormat:@"https://www.curseforge.com/api/v1/mods/%llu/files/%llu/download", projectID, fileID];
        
        // 3) Next fallback: attempt to build a media.forgecdn.net link
        endpoint = [NSString stringWithFormat:@"mods/%llu/files/%llu", projectID, fileID];
        NSDictionary *fallbackResponse = [self getEndpoint:endpoint params:nil];
        if (fallbackResponse && fallbackResponse[@"data"] && ![fallbackResponse[@"data"] isKindOfClass:[NSNull class]]) {
            NSDictionary *modData = fallbackResponse[@"data"];
            NSNumber *idNumber = modData[@"id"];
            if (idNumber) {
                unsigned long long idValue = [idNumber unsignedLongLongValue];
                NSString *fileName = modData[@"fileName"];
                if (fileName) {
                    NSString *mediaLink = [NSString stringWithFormat:@"https://media.forgecdn.net/files/%llu/%llu/%@", idValue / 1000, idValue % 1000, fileName];
                    if (mediaLink) {
                        downloadUrl = mediaLink;
                    }
                }
            }
        }
        
        dispatch_semaphore_signal(semaphore);
    });
    
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    return downloadUrl;
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
