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
// Redeclare apiKey as readwrite (header declares it readonly)
@property (nonatomic, strong) NSString *apiKey;

// Private helper methods
- (BOOL)verifyManifestFromDictionary:(NSDictionary *)manifest;
- (NSString *)getDownloadUrlForProject:(unsigned long long)projectID fileID:(unsigned long long)fileID;
@end

@implementation CurseForgeAPI

#pragma mark - Initialization

- (instancetype)initWithAPIKey:(NSString *)apiKey {
    // Assumes CurseForgeAPI is a subclass of ModpackAPI (which provides -initWithURL:)
    self = [super initWithURL:@"https://api.curseforge.com/v1"];
    if (self) {
        self.apiKey = apiKey;
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

#pragma mark - Download Tasks from Package

- (void)downloader:(MinecraftResourceDownloadTask *)downloader
submitDownloadTasksFromPackage:(NSString *)packagePath
            toPath:(NSString *)destPath {
    NSError *error = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
    if (error || !archive) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to open modpack package: %@", error.localizedDescription]];
        return;
    }
    
    NSData *manifestData = [archive extractDataFromFile:@"manifest.json" error:&error];
    if (error || !manifestData) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract manifest.json: %@", error.localizedDescription]];
        return;
    }
    
    NSDictionary *manifestDict = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:&error];
    if (error || !manifestDict) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to parse manifest.json: %@", error.localizedDescription]];
        return;
    }
    
    if (![self verifyManifestFromDictionary:manifestDict]) {
        [downloader finishDownloadWithErrorString:@"Manifest verification failed"];
        return;
    }
    
    // Deduplicate file entries using projectID and fileID.
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
    
    // Calculate total download tasks from deduplicated files.
    NSUInteger totalDownloads = 0;
    for (NSDictionary *fileEntry in files) {
        NSNumber *projectID = fileEntry[@"projectID"];
        NSNumber *fileID = fileEntry[@"fileID"];
        BOOL required = [fileEntry[@"required"] boolValue];
        NSString *url = [self getDownloadUrlForProject:[projectID unsignedLongLongValue] fileID:[fileID unsignedLongLongValue]];
        if (url || !required) {
            totalDownloads++;
        }
    }
    downloader.progress.totalUnitCount = totalDownloads;
    
    // Create download tasks for each deduplicated file entry.
    for (NSDictionary *fileEntry in files) {
        NSNumber *projectID = fileEntry[@"projectID"];
        NSNumber *fileID = fileEntry[@"fileID"];
        BOOL required = [fileEntry[@"required"] boolValue];
        
        NSString *url = [self getDownloadUrlForProject:[projectID unsignedLongLongValue] fileID:[fileID unsignedLongLongValue]];
        if (!url && required) {
            NSString *modName = fileEntry[@"fileName"];
            if (!modName || modName.length == 0) {
                modName = [NSString stringWithFormat:@"Project %@ File %@", projectID, fileID];
            }
            [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to obtain download URL for modpack '%@' and mod '%@'", modpackName, modName]];
            return;
        } else if (!url) {
            downloader.progress.completedUnitCount++;
            continue;
        }
        
        // Determine the final file name.
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
        
        // Use fileLength if available; default to 1.
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
    
    // Extract overrides.
    [ModpackUtils archive:archive extractDirectory:@"overrides" toPath:destPath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract overrides: %@", error.localizedDescription]];
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
    
    // Process version and profile information.
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
}

#pragma mark - Additional Fallback Link Logic

- (NSString *)getDownloadUrlForProject:(unsigned long long)projectID fileID:(unsigned long long)fileID {
    // 1) Attempt the official endpoint with two attempts.
    NSString *endpoint = [NSString stringWithFormat:@"mods/%llu/files/%llu/download-url", projectID, fileID];
    NSDictionary *response = nil;
    for (int attempt = 0; attempt < 2; attempt++) {
        response = [self getEndpoint:endpoint params:nil];
        if (response && response[@"data"] && ![response[@"data"] isKindOfClass:[NSNull class]]) {
            return [NSString stringWithFormat:@"%@", response[@"data"]];
        }
        [NSThread sleepForTimeInterval:0.5];
    }
    
    // 2) Fallback: direct CurseForge API link.
    NSString *directDownloadUrl = [NSString stringWithFormat:
        @"https://www.curseforge.com/api/v1/mods/%llu/files/%llu/download",
        projectID, fileID];
    
    // 3) Next fallback: attempt to build a media.forgecdn.net link using file metadata.
    endpoint = [NSString stringWithFormat:@"mods/%llu/files/%llu", projectID, fileID];
    NSDictionary *fallbackResponse = [self getEndpoint:endpoint params:nil];
    if (fallbackResponse && fallbackResponse[@"data"] && ![fallbackResponse[@"data"] isKindOfClass:[NSNull class]]) {
        NSDictionary *modData = fallbackResponse[@"data"];
        NSNumber *idNumber = modData[@"id"];
        if (idNumber) {
            unsigned long long idValue = [idNumber unsignedLongLongValue];
            NSString *fileName = modData[@"fileName"];
            if (fileName) {
                NSString *mediaLink = [NSString stringWithFormat:
                    @"https://media.forgecdn.net/files/%llu/%llu/%@",
                    idValue / 1000, idValue % 1000, fileName];
                if (mediaLink) {
                    return mediaLink;
                }
            }
        }
    }
    
    // 4) If all else fails, return the direct API fallback link.
    return directDownloadUrl;
}

#pragma mark - Implementation for verifyManifestFromDictionary:

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
