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

@interface CurseForgeAPI () {
    dispatch_queue_t _networkQueue;
    dispatch_queue_t _cacheQueue;
}

@property (nonatomic, strong) NSString *apiKey;
@property (nonatomic, strong) NSOperationQueue *downloadQueue;

@end

@implementation CurseForgeAPI

#pragma mark - Initialization

- (instancetype)initWithAPIKey:(NSString *)apiKey {
    self = [super initWithURL:@"https://api.curseforge.com/v1"];
    if (self) {
        _networkQueue = dispatch_queue_create("com.yourapp.network", DISPATCH_QUEUE_SERIAL);
        _cacheQueue = dispatch_queue_create("com.yourapp.cache", DISPATCH_QUEUE_SERIAL);
        self.apiKey = apiKey;
        self.downloadQueue = [[NSOperationQueue alloc] init];
        self.downloadQueue.maxConcurrentOperationCount = 3;
    }
    return self;
}

#pragma mark - Network Operations

- (id)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params {
    __block id result = nil;
    dispatch_group_t group = dispatch_group_create();
    
    dispatch_group_enter(group);
    dispatch_async(_networkQueue, ^{
        AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
        manager.requestSerializer.timeoutInterval = 30.0;
        
        NSString *key = self.apiKey;
        if (key.length == 0) {
            char *envKey = getenv("CURSEFORGE_API_KEY");
            if (envKey) {
                key = [NSString stringWithUTF8String:envKey];
            }
        }
        [manager.requestSerializer setValue:key forHTTPHeaderField:@"x-api-key"];
        
        [manager GET:endpoint parameters:params headers:nil progress:nil
             success:^(NSURLSessionTask *task, id obj) {
                 result = obj;
                 dispatch_group_leave(group);
             }
             failure:^(NSURLSessionTask *operation, NSError *error) {
                 self.lastError = error;
                 dispatch_group_leave(group);
             }];
    });
    
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    return result;
}

#pragma mark - Search Operations

- (void)searchModWithFilters:(NSDictionary *)searchFilters
         previousPageResult:(NSMutableArray *)prevResult
                 completion:(void (^)(NSMutableArray *results, NSError *error))completion {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
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
            
            NSError *error = nil;
            NSDictionary *response = [weakSelf getEndpoint:@"mods/search" params:params];
            if (!response) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(nil, weakSelf.lastError);
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
            
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(result, nil);
            });
        }
    });
}

#pragma mark - Manifest Operations

+ (NSCache<NSString *, NSDictionary *> *)manifestCache {
    static NSCache<NSString *, NSDictionary *> *cache = nil;
    static dispatch_once_t onceToken;
    
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.totalCostLimit = 1024 * 1024 * 10; // 10MB limit
        cache.countLimit = 20;
    });
    return cache;
}

- (void)asyncExtractManifestFromPackage:(NSString *)packagePath
                             completion:(void (^)(NSDictionary *manifestDict, NSError *error))completion {
    __weak typeof(self) weakSelf = self;
    dispatch_async(_cacheQueue, ^{
        @autoreleasepool {
            NSDictionary *cachedManifest = [[CurseForgeAPI manifestCache] objectForKey:packagePath];
            if (cachedManifest) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(cachedManifest, nil);
                });
                return;
            }
            
            NSError *error = nil;
            UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
            if (!archive) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(nil, error);
                });
                return;
            }
            
            NSString *tempManifestPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                        [NSString stringWithFormat:@"manifest_%@", [[NSUUID UUID] UUIDString]]];
            
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                @autoreleasepool {
                    NSError *extractError = nil;
                    NSData *extractedData = [archive extractDataFromFile:@"manifest.json" error:&extractError];
                    if (!extractedData || extractError) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            completion(nil, extractError);
                        });
                        return;
                    }
                    
                    NSError *writeError = nil;
                    if (![extractedData writeToFile:tempManifestPath options:NSDataWritingAtomic error:&writeError]) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            completion(nil, writeError);
                        });
                        return;
                    }
                    
                    NSError *readError = nil;
                    NSData *manifestData = [NSData dataWithContentsOfFile:tempManifestPath options:NSDataReadingMappedIfSafe error:&readError];
                    [[NSFileManager defaultManager] removeItemAtPath:tempManifestPath error:nil];
                    
                    if (!manifestData || readError) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            completion(nil, readError);
                        });
                        return;
                    }
                    
                    NSError *jsonError = nil;
                    NSDictionary *manifestDict = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:&jsonError];
                    if (manifestDict && !jsonError) {
                        [[CurseForgeAPI manifestCache] setObject:manifestDict forKey:packagePath];
                    }
                    
                    dispatch_async(dispatch_get_main_queue(), ^{
                        completion(manifestDict, jsonError);
                    });
                }
            });
        }
    });
}

#pragma mark - Mod Details Loading

- (void)loadDetailsOfMod:(NSMutableDictionary *)item
              completion:(void (^)(NSError *error))completion {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @autoreleasepool {
            NSString *modId = [NSString stringWithFormat:@"%@", item[@"id"]];
            NSDictionary *response = [weakSelf getEndpoint:[NSString stringWithFormat:@"mods/%@/files", modId] params:nil];
            if (!response) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(weakSelf.lastError);
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
        }
    });
}

#pragma mark - Modpack Installation

- (void)installModpackFromDetail:(NSDictionary *)modDetail
                         atIndex:(NSUInteger)selectedVersion
                      completion:(void (^)(NSError *error))completion {
    NSArray *versionNames = modDetail[@"versionNames"];
    if (selectedVersion >= versionNames.count) {
        NSError *error = [NSError errorWithDomain:@"CurseForgeAPIErrorDomain"
                                            code:100
                                        userInfo:@{NSLocalizedDescriptionKey: @"Selected version index is out of bounds."}];
        completion(error);
        return;
    }
    
    [super installModpackFromDetail:modDetail atIndex:selectedVersion];
    if (completion) {
        completion(nil);
    }
}

#pragma mark - Download URL Generation

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
