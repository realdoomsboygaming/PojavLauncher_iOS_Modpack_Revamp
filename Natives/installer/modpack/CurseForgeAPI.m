#import <Foundation/Foundation.h>
#import <AFNetworking/AFNetworking.h>
#import "CurseForgeAPI.h"

#define CURSEFORGE_API_URL @"https://api.curseforge.com/v1"
#define CURSEFORGE_MINECRAFT_GAME_ID 432
#define CURSEFORGE_MODPACK_CLASS_ID 4471
#define CURSEFORGE_MOD_CLASS_ID 6
#define CURSEFORGE_PAGE_SIZE 50

@implementation CurseForgeFile
@end

@implementation CurseForgeManifest
@end

@implementation CurseForgeAPI {
    AFHTTPSessionManager *_manager;
    NSString *_apiKey;
}

- (instancetype)initWithAPIKey:(NSString *)apiKey {
    self = [super init];
    if (self) {
        _apiKey = apiKey;
        _manager = [AFHTTPSessionManager manager];
        _manager.requestSerializer = [AFJSONRequestSerializer serializer];
        [_manager.requestSerializer setValue:_apiKey forHTTPHeaderField:@"x-api-key"];
    }
    return self;
}

- (void)searchModsWithFilters:(NSDictionary *)filters previousPageResult:(NSArray *)previousResults completion:(void (^)(NSArray *results, BOOL hasMore, NSError *error))completion {
    NSMutableDictionary *params = [@{
        @"gameId": @(CURSEFORGE_MINECRAFT_GAME_ID),
        @"classId": filters[@"isModpack"] ? @(CURSEFORGE_MODPACK_CLASS_ID) : @(CURSEFORGE_MOD_CLASS_ID),
        @"searchFilter": filters[@"name"] ?: @"",
        @"pageSize": @(CURSEFORGE_PAGE_SIZE),
        @"sortOrder": @"desc"
    } mutableCopy];
    
    if (filters[@"mcVersion"]) {
        params[@"gameVersion"] = filters[@"mcVersion"];
    }
    
    if (previousResults) {
        params[@"index"] = @([previousResults count]);
    }
    
    [_manager GET:[CURSEFORGE_API_URL stringByAppendingPathComponent:@"/mods/search"]
       parameters:params
          headers:nil
         progress:nil
          success:^(NSURLSessionDataTask *task, id responseObject) {
              NSArray *data = responseObject[@"data"];
              NSMutableArray *results = [NSMutableArray array];
              
              for (NSDictionary *modData in data) {
                  if (![modData[@"allowModDistribution"] boolValue] && ![modData[@"allowModDistribution"] isKindOfClass:[NSNull class]]) {
                      continue;
                  }
                  
                  NSDictionary *modItem = @{
                      @"id": modData[@"id"] ?: @"",
                      @"title": modData[@"name"] ?: @"",
                      @"description": modData[@"summary"] ?: @"",
                      @"imageUrl": modData[@"logo"][@"thumbnailUrl"] ?: @"",
                      @"isModpack": filters[@"isModpack"]
                  };
                  [results addObject:modItem];
              }
              
              NSDictionary *pagination = responseObject[@"pagination"];
              BOOL hasMore = [pagination[@"totalCount"] integerValue] > [previousResults count] + results.count;
              completion([previousResults arrayByAddingObjectsFromArray:results], hasMore, nil);
          }
          failure:^(NSURLSessionDataTask *task, NSError *error) {
              completion(nil, NO, error);
          }];
}

- (void)getModDetails:(NSString *)modId completion:(void (^)(NSDictionary *details, NSError *error))completion {
    NSMutableArray *allFiles = [NSMutableArray array];
    [self fetchPaginatedFiles:modId index:0 allFiles:allFiles completion:completion];
}

- (void)fetchPaginatedFiles:(NSString *)modId index:(NSInteger)index allFiles:(NSMutableArray *)allFiles completion:(void (^)(NSDictionary *, NSError *))completion {
    NSDictionary *params = @{
        @"index": @(index),
        @"pageSize": @(CURSEFORGE_PAGE_SIZE)
    };
    
    NSString *url = [NSString stringWithFormat:@"/mods/%@/files", modId];
    [_manager GET:[CURSEFORGE_API_URL stringByAppendingPathComponent:url]
       parameters:params
          headers:nil
         progress:nil
          success:^(NSURLSessionDataTask *task, id responseObject) {
              NSArray *data = responseObject[@"data"];
              if (!data) {
                  completion(nil, [NSError errorWithDomain:@"CurseForgeAPI" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid response format"}]);
                  return;
              }
              
              for (NSDictionary *fileData in data) {
                  if ([fileData[@"isServerPack"] boolValue]) continue;
                  [allFiles addObject:fileData];
              }
              
              if (data.count < CURSEFORGE_PAGE_SIZE) {
                  [self processFiles:allFiles modId:modId completion:completion];
              } else {
                  [self fetchPaginatedFiles:modId index:index + data.count allFiles:allFiles completion:completion];
              }
          }
          failure:^(NSURLSessionDataTask *task, NSError *error) {
              completion(nil, error);
          }];
}

- (void)processFiles:(NSArray *)files modId:(NSString *)modId completion:(void (^)(NSDictionary *details, NSError *error))completion {
    NSMutableArray *versionNames = [NSMutableArray array];
    NSMutableArray *mcVersions = [NSMutableArray array];
    NSMutableArray *fileUrls = [NSMutableArray array];
    NSMutableArray *hashes = [NSMutableArray array];
    
    for (NSDictionary *fileData in files) {
        [versionNames addObject:fileData[@"displayName"] ?: @""];
        
        NSString *downloadUrl = fileData[@"downloadUrl"];
        if (!downloadUrl) {
            NSInteger fileId = [fileData[@"id"] integerValue];
            NSString *fileName = fileData[@"fileName"] ?: @"";
            downloadUrl = [NSString stringWithFormat:@"https://edge.forgecdn.net/files/%ld/%03ld/%@", 
                         fileId/1000, fileId%1000, fileName];
        }
        [fileUrls addObject:downloadUrl];
        
        NSString *sha1 = @"";
        for (NSDictionary *hashEntry in fileData[@"hashes"]) {
            if ([hashEntry[@"algo"] integerValue] == 1) {
                sha1 = hashEntry[@"value"] ?: @"";
                break;
            }
        }
        [hashes addObject:sha1];
        
        NSString *mcVersion = @"";
        for (NSString *version in fileData[@"gameVersions"]) {
            NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^\\d+\\.\\d+(\\.\\d+)?$" options:0 error:nil];
            if ([regex numberOfMatchesInString:version options:0 range:NSMakeRange(0, version.length)] > 0) {
                mcVersion = version;
                break;
            }
        }
        [mcVersions addObject:mcVersion];
    }
    
    NSDictionary *details = @{
        @"versionNames": versionNames,
        @"mcVersionNames": mcVersions,
        @"versionUrls": fileUrls,
        @"hashes": hashes,
        @"versionDetailsLoaded": @YES
    };
    
    completion(details, nil);
}

- (void)installModpackFromDetail:(NSDictionary *)detail atIndex:(NSInteger)index completion:(void (^)(BOOL success, NSError *error))completion {
    NSString *downloadUrl = detail[@"versionUrls"][index];
    NSURL *zipURL = [NSURL URLWithString:downloadUrl];
    
    NSURLSessionDownloadTask *task = [_manager downloadTaskWithRequest:[NSURLRequest requestWithURL:zipURL]
        progress:nil
        destination:^NSURL *(NSURL *targetPath, NSURLResponse *response) {
            return [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:response.suggestedFilename]];
        }
        completionHandler:^(NSURLResponse *response, NSURL *filePath, NSError *error) {
            if (error) {
                completion(NO, error);
                return;
            }
            
            NSError *zipError;
            CurseForgeManifest *manifest = [self extractManifestFromZip:filePath.path error:&zipError];
            if (!manifest) {
                completion(NO, zipError);
                return;
            }
            
            [self installDependencies:manifest completion:completion];
        }];
    
    [task resume];
}

- (CurseForgeManifest *)extractManifestFromZip:(NSString *)zipPath error:(NSError **)error {
    return nil;
}

- (void)installDependencies:(CurseForgeManifest *)manifest completion:(void (^)(BOOL success, NSError *error))completion {
}

@end
