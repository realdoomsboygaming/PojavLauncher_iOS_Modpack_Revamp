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
#define CURSEFORGE_PAGINATION_END_REACHED -1
#define CURSEFORGE_PAGINATION_ERROR -2

@interface CurseForgeAPI ()
@property (nonatomic, copy) NSString *apiKey;
@end

@implementation CurseForgeAPI

#pragma mark - Initialization

- (instancetype)initWithAPIKey:(NSString *)apiKey {
    self = [super initWithURL:@"https://api.curseforge.com/v1"];
    if (self) {
        self.apiKey = apiKey;
    }
    return self;
}

#pragma mark - Overridden GET Endpoint

- (id)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params {
    __block id result;
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);

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
             dispatch_group_leave(group);
         }
         failure:^(NSURLSessionTask *operation, NSError *error) {
             self.lastError = error;
             dispatch_group_leave(group);
         }];
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    return result;
}

#pragma mark - Asynchronous API Methods

- (void)searchModWithFilters:(NSDictionary *)searchFilters
         previousPageResult:(NSMutableArray *)prevResult
                 completion:(void (^ _Nonnull)(NSMutableArray * _Nullable results, NSError * _Nullable error))completion
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
            @"sortField": @(1), // relevancy
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
                @"title": (mod[@"name"]
                           ? [NSString stringWithFormat:@"%@", mod[@"name"]]
                           : @""),
                @"description": (mod[@"summary"]
                                 ? [NSString stringWithFormat:@"%@", mod[@"summary"]]
                                 : @""),
                @"imageUrl": (mod[@"logo"]
                              ? [NSString stringWithFormat:@"%@", mod[@"logo"]]
                              : @"")
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
              completion:(void (^ _Nonnull)(NSError * _Nullable error))completion
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *modId = [NSString stringWithFormat:@"%@", item[@"id"]];
        NSDictionary *response = [self getEndpoint:[NSString stringWithFormat:@"mods/%@/files", modId]
                                            params:nil];
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
        
        [files enumerateObjectsUsingBlock:^(NSDictionary *file, NSUInteger i, BOOL *stop) {
            // File name
            [names addObject:[NSString stringWithFormat:@"%@", file[@"fileName"] ?: @""]];
            // Minecraft version
            id versions = file[@"gameVersion"] ?: file[@"gameVersionList"];
            NSString *gameVersion = @"";
            if ([versions isKindOfClass:[NSArray class]] && [versions count] > 0) {
                gameVersion = [NSString stringWithFormat:@"%@", ((NSArray *)versions)[0]];
            } else if ([versions isKindOfClass:[NSString class]]) {
                gameVersion = [NSString stringWithFormat:@"%@", versions];
            }
            [mcNames addObject:gameVersion];

            // Download URL
            [urls addObject:[NSString stringWithFormat:@"%@", file[@"downloadUrl"] ?: @""]];

            // File length
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
            
            // SHA1 hash
            NSString *sha1 = @"";
            NSArray *hashesArray = file[@"hashes"];
            for (NSDictionary *hashDict in hashesArray) {
                if ([[NSString stringWithFormat:@"%@", hashDict[@"algo"]] isEqualToString:@"SHA1"]) {
                    sha1 = [NSString stringWithFormat:@"%@", hashDict[@"value"]];
                    break;
                }
            }
            [hashes addObject:sha1];
        }];
        
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
    // Optionally implement your own code. For now, calls the superclass if it handles the actual install:
    [super installModpackFromDetail:modDetail atIndex:selectedVersion];
    if (completion) {
        completion(nil);
    }
}

#pragma mark - Download Tasks from Package

- (void)downloader:(MinecraftResourceDownloadTask *)downloader
submitDownloadTasksFromPackage:(NSString *)packagePath
            toPath:(NSString *)destPath
{
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
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
        
        NSArray *files = manifestDict[@"files"];
        if (![files isKindOfClass:[NSArray class]]) {
            [downloader finishDownloadWithErrorString:@"Manifest files missing"];
            return;
        }
        
        // Use the file count as total progress units
        downloader.progress.totalUnitCount = files.count;
        
        // Submit download tasks for each file
        for (NSDictionary *fileEntry in files) {
            NSNumber *projectID = fileEntry[@"projectID"];
            NSNumber *fileID = fileEntry[@"fileID"];
            BOOL required = [fileEntry[@"required"] boolValue];
            
            NSString *url = [self getDownloadUrlForProject:[projectID unsignedLongLongValue]
                                                    fileID:[fileID unsignedLongLongValue]];
            if (!url && required) {
                [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to obtain download URL for project %@ file %@", projectID, fileID]];
                return;
            } else if (!url) {
                // This is an optional file with no URL. Skip.
                continue;
            }
            
            NSString *relativePath = fileEntry[@"path"];
            if (!relativePath || relativePath.length == 0) {
                relativePath = [NSString stringWithFormat:@"%@.jar", fileID];
            }
            
            NSString *destinationPath = [destPath stringByAppendingPathComponent:relativePath];
            NSURLSessionDownloadTask *task = [downloader createDownloadTask:url
                                                                       size:0
                                                                       sha:nil
                                                                   altName:nil
                                                                     toPath:destinationPath];
            if (task) {
                [downloader.fileList addObject:relativePath];
                [task resume];
            } else if (!downloader.progress.cancelled) {
                downloader.progress.completedUnitCount++;
            } else {
                return; // cancelled
            }
        }
        
        // Extract the "overrides" directory
        [ModpackUtils archive:archive extractDirectory:@"overrides" toPath:destPath error:&error];
        if (error) {
            [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract overrides: %@", error.localizedDescription]];
            return;
        }
        
        // Clean up the package
        [[NSFileManager defaultManager] removeItemAtPath:packagePath error:nil];
        
        // Download dependency JSON if it's a Fabric-based pack
        NSDictionary<NSString *, NSString *> *depInfo = [ModpackUtils infoForDependencies:manifestDict[@"dependencies"]];
        if (depInfo[@"json"]) {
            NSString *jsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json",
                                  getenv("POJAV_GAME_DIR"), depInfo[@"id"]];
            NSURLSessionDownloadTask *task = [downloader createDownloadTask:depInfo[@"json"] size:0 sha:nil altName:nil toPath:jsonPath];
            [task resume];
        }
        
        // Build the final version string (Forge/Fabric, etc.)
        NSDictionary *minecraft = manifestDict[@"minecraft"];
        NSString *vanillaVersion = @"";
        NSString *modLoaderId = @"";
        NSString *modLoaderVersion = @"";
        
        if (minecraft && [minecraft isKindOfClass:[NSDictionary class]]) {
            vanillaVersion = minecraft[@"version"] ?: @"";
            NSArray *modLoaders = minecraft[@"modLoaders"];
            NSDictionary *primaryModLoader = nil;
            
            if ([modLoaders isKindOfClass:[NSArray class]] && modLoaders.count > 0) {
                // Find the primary
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
                        // e.g. "forge-36.2.0"
                        // finalVersion: "<vanilla>-forge-<loaderVer>"
                        modLoaderVersion = [NSString stringWithFormat:@"forge-%@", loaderVer];
                        modLoaderId = @"forge";
                    } else if ([loaderName isEqualToString:@"fabric"]) {
                        // "fabric-loader-<loaderVer>-<vanilla>"
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
            // "<vanilla>-forge-<loaderVer>"
            finalVersionString = [NSString stringWithFormat:@"%@-%@", vanillaVersion, modLoaderVersion];
        } else if ([modLoaderId isEqualToString:@"fabric"]) {
            // Already "fabric-loader-<ver>-<vanilla>"
            finalVersionString = modLoaderVersion;
        } else {
            finalVersionString = [NSString stringWithFormat:@"%@ | %@", vanillaVersion, modLoaderId];
        }
        
        NSString *profileName = manifestDict[@"name"];
        if (profileName) {
            NSDictionary *profileInfo = @{
                @"gameDir": [NSString stringWithFormat:@"./custom_gamedir/%@", [destPath lastPathComponent]],
                @"name": profileName,
                @"lastVersionId": finalVersionString,
                @"icon": @""
            };
            PLProfiles.current.profiles[profileName] = [profileInfo mutableCopy];
            PLProfiles.current.selectedProfileName = profileName;
        }
    });
}

- (BOOL)verifyManifestFromDictionary:(NSDictionary *)manifest {
    if (![manifest[@"manifestType"] isEqualToString:@"minecraftModpack"]) return NO;
    if ([manifest[@"manifestVersion"] integerValue] != 1) return NO;
    if (manifest[@"minecraft"] == nil) return NO;
    NSDictionary *minecraft = manifest[@"minecraft"];
    if (minecraft[@"version"] == nil) return NO;
    if (minecraft[@"modLoaders"] == nil) return NO;
    NSArray *modLoaders = minecraft[@"modLoaders"];
    return (modLoaders.count >= 1);
}

- (NSString *)getDownloadUrlForProject:(unsigned long long)projectID fileID:(unsigned long long)fileID {
    NSString *endpoint = [NSString stringWithFormat:@"mods/%llu/files/%llu/download-url", projectID, fileID];
    NSDictionary *response = [self getEndpoint:endpoint params:nil];
    if (response && response[@"data"] && ![response[@"data"] isKindOfClass:[NSNull class]]) {
        return [NSString stringWithFormat:@"%@", response[@"data"]];
    }
    
    endpoint = [NSString stringWithFormat:@"mods/%llu/files/%llu", projectID, fileID];
    NSDictionary *fallbackResponse = [self getEndpoint:endpoint params:nil];
    if (fallbackResponse && fallbackResponse[@"data"] && ![fallbackResponse[@"data"] isKindOfClass:[NSNull class]]) {
        NSDictionary *modData = fallbackResponse[@"data"];
        NSNumber *idNumber = modData[@"id"];
        if (idNumber) {
            unsigned long long idValue = [idNumber unsignedLongLongValue];
            NSString *fileName = modData[@"fileName"];
            if (fileName) {
                // e.g. "https://edge.forgecdn.net/files/1234/5678/example.jar"
                return [NSString stringWithFormat:@"https://edge.forgecdn.net/files/%llu/%llu/%@",
                        idValue / 1000,
                        idValue % 1000,
                        fileName];
            }
        }
    }
    return nil;
}

@end
