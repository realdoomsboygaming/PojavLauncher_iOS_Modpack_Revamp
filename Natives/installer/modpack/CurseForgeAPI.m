#import <Foundation/Foundation.h>
#import "CurseforgeAPI.h"

static NSString *const CurseForgeAPIBaseURL = @"https://api.curseforge.com/v1";
static NSInteger const CurseForgeMinecraftGameID = 432;
static NSInteger const CurseForgeModpackClassID = 4471;
static NSInteger const CurseForgeModClassID = 6;
static NSInteger const CurseForgeSortRelevance = 1;
static NSInteger const CurseForgePaginationSize = 50;

@implementation CurseforgeAPI

- (instancetype)initWithApiKey:(NSString *)apiKey {
    self = [super init];
    if (self) {
        _apiKey = apiKey;
    }
    return self;
}

#pragma mark - Search Mods and Modpacks

- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, NSString *> *)searchFilters previousPageResult:(NSMutableArray *)curseforgeSearchResult {
    NSInteger limit = CurseForgePaginationSize;

    NSMutableString *facetString = [NSMutableString new];
    [facetString appendString:@"["];
    [facetString appendFormat:@"[\"classId:%@\"]", searchFilters[@"isModpack"] ? @(CurseForgeModpackClassID) : @(CurseForgeModClassID)];
    if (searchFilters[@"mcVersion"].length > 0) {
        [facetString appendFormat:@",[\"gameVersion:%@\"]", searchFilters[@"mcVersion"]];
    }
    [facetString appendString:@"]"];

    NSDictionary *params = @{
        @"gameId": @(CurseForgeMinecraftGameID),
        @"searchFilter": searchFilters[@"name"],
        @"classId": searchFilters[@"isModpack"] ? @(CurseForgeModpackClassID) : @(CurseForgeModClassID),
        @"limit": @(limit),
        @"offset": @(curseforgeSearchResult.count),
        @"sortField": @(CurseForgeSortRelevance),
        @"sortOrder": @"desc"
    };

    NSDictionary *response = [self getEndpoint:@"mods/search" params:params];
    if (!response) {
        return nil;
    }

    NSMutableArray *result = curseforgeSearchResult ?: [NSMutableArray new];
    for (NSDictionary *hit in response[@"data"]) {
        [result addObject:@{
            @"apiSource": @(1), // Constant CURSEFORGE
            @"isModpack": @(searchFilters[@"isModpack"] ? YES : NO),
            @"id": hit[@"id"],
            @"title": hit[@"name"],
            @"description": hit[@"summary"],
            @"imageUrl": hit[@"logo"] ? hit[@"logo"][@"thumbnailUrl"] : @""
        }];
    }
    return result;
}

#pragma mark - Get Mod Details

- (void)loadModDetails:(NSDictionary *)modItem completion:(void (^)(NSDictionary *))completion {
    NSString *modId = modItem[@"id"];
    NSDictionary *params = @{
        @"index": @(0),
        @"pageSize": @(CurseForgePaginationSize)
    };

    NSDictionary *response = [self getEndpoint:[NSString stringWithFormat:@"mods/%@/files", modId] params:params];
    if (!response) {
        completion(nil);
        return;
    }

    NSMutableArray *versionNames = [NSMutableArray new];
    NSMutableArray *mcNames = [NSMutableArray new];
    NSMutableArray *urls = [NSMutableArray new];
    NSMutableArray *hashes = [NSMutableArray new];

    for (NSDictionary *fileInfo in response[@"data"]) {
        [versionNames addObject:fileInfo[@"displayName"]];
        [mcNames addObject:fileInfo[@"gameVersions"][0]]; // Assuming the first game version is relevant.
        [urls addObject:fileInfo[@"downloadUrl"]];
        [hashes addObject:fileInfo[@"hashes"][@"sha1"]];
    }

    NSDictionary *modDetails = @{
        @"versionNames": versionNames,
        @"mcVersionNames": mcNames,
        @"versionUrls": urls,
        @"versionHashes": hashes
    };

    completion(modDetails);
}

#pragma mark - Download Modpack

- (void)downloadModpack:(NSString *)modpackId destinationPath:(NSString *)destinationPath completion:(void (^)(BOOL success, NSError *error))completion {
    NSString *urlString = [NSString stringWithFormat:@"https://api.curseforge.com/v1/mods/%@/files", modpackId];
    
    // Fetch modpack details and download URLs
    NSDictionary *response = [self getEndpoint:urlString params:nil];
    if (!response || !response[@"data"]) {
        completion(NO, [NSError errorWithDomain:@"CurseforgeAPI" code:100 userInfo:@{NSLocalizedDescriptionKey: @"Failed to fetch modpack files."}]);
        return;
    }

    // Download each file in the modpack (loop through response)
    NSArray *files = response[@"data"];
    for (NSDictionary *file in files) {
        NSString *fileUrl = file[@"downloadUrl"];
        if (fileUrl) {
            // Use NSURLSession or any download manager to handle file download
            [self downloadFileWithURL:fileUrl destinationPath:destinationPath completion:^(BOOL success, NSError *error) {
                if (!success) {
                    completion(NO, error);
                    return;
                }
                // Handle file extraction and any other post-download tasks here.
                completion(YES, nil);
            }];
        }
    }
}

#pragma mark - Helper Methods for File Downloads

// Helper method for downloading files
- (void)downloadFileWithURL:(NSString *)urlString destinationPath:(NSString *)destinationPath completion:(void (^)(BOOL success, NSError *error))completion {
    NSURL *url = [NSURL URLWithString:urlString];
    NSURLSessionDownloadTask *downloadTask = [[NSURLSession sharedSession] downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        if (error) {
            completion(NO, error);
        } else {
            NSError *moveError = nil;
            [[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:destinationPath] error:&moveError];
            if (moveError) {
                completion(NO, moveError);
            } else {
                completion(YES, nil);
            }
        }
    }];
    [downloadTask resume];
}

#pragma mark - API Call to Fetch Endpoint

// Make API request
- (NSDictionary *)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params {
    NSString *urlString = [NSString stringWithFormat:@"%@/%@", CurseForgeAPIBaseURL, endpoint];
    NSURL *url = [NSURL URLWithString:urlString];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", self.apiKey] forHTTPHeaderField:@"Authorization"];
    
    if (params) {
        NSError *error;
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:params options:0 error:&error];
        if (error) {
            return nil;
        }
        [request setHTTPBody:jsonData];
    }
    
    NSURLSession *session = [NSURLSession sharedSession];
    __block NSDictionary *responseDict = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    NSURLSessionDataTask *dataTask = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            responseDict = nil;
        } else {
            responseDict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        }
        dispatch_semaphore_signal(semaphore);
    }];
    [dataTask resume];
    
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    return responseDict;
}

@end
