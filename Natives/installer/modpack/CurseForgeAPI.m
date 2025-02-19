#import "CurseForgeAPI.h"
#import "utils.h"
#import "UZKArchive.h"
#import "ModpackUtils.h" 

static const NSInteger kCurseForgeGameIDMinecraft = 432;
static const NSInteger kCurseForgeClassIDModpack = 4471;
static const NSInteger kCurseForgeClassIDMod = 6;

@implementation CurseForgeAPI

- (instancetype)initWithAPIKey:(NSString *)apiKeyVal {
    self = [super initWithBaseURL:[NSURL URLWithString:@"https://api.curseforge.com/v1"]];
    if (self) {
        _apiKey = apiKeyVal; // Use synthesized ivar
        _previousOffset = 0;
        self.requestSerializer = [AFJSONRequestSerializer serializer];
        [self.requestSerializer setValue:_apiKey forHTTPHeaderField:@"x-api-key"];
    }
    return self;
}

- (NSString *)loadAPIKey {
    NSDictionary *environment = [[NSProcessInfo processInfo] environment];
    NSString *envKey = environment[@"CURSEFORGE_API_KEY"];
    if (!envKey || [envKey length] == 0) { // Rename local variable
        NSLog(@"⚠️ WARNING: CurseForge API key missing!");
    }
    return envKey;
}

- (id)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params {
    __block id result;
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);
    
    NSString *url = [self.baseURL stringByAppendingPathComponent:endpoint];
    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    [manager.requestSerializer setValue:self.apiKey forHTTPHeaderField:@"x-api-key"];
    [manager.requestSerializer setValue:@"Mozilla/5.0" forHTTPHeaderField:@"User-Agent"];
    
    [manager GET:url parameters:params headers:nil progress:nil
         success:^(NSURLSessionTask *task, id responseObject) {
             result = responseObject;
             dispatch_group_leave(group);
         } failure:^(NSURLSessionTask *operation, NSError *error) {
             self.lastError = error;
             dispatch_group_leave(group);
         }];
    
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    return result;
}

- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, id> *)searchFilters previousPageResult:(NSMutableArray *)previousResults {
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    params[@"gameId"] = @(kCurseForgeGameIDMinecraft);
    
    BOOL isModpack = [searchFilters[@"isModpack"] boolValue];
    params[@"classId"] = isModpack ? @(kCurseForgeClassIDModpack) : @(kCurseForgeClassIDMod);
    params[@"searchFilter"] = searchFilters[@"name"];
    params[@"sortField"] = @(1);
    params[@"sortOrder"] = @"desc";
    
    int limit = 50;
    params[@"pageSize"] = @(limit);
    
    // Reset offset if this is a new search
    if (!previousResults || ![searchFilters[@"name"] isEqualToString:self.lastSearchTerm]) {
        self.previousOffset = 0;
        self.reachedLastPage = NO;
    }
    
    params[@"index"] = @(self.previousOffset);
    
    if (searchFilters[@"mcVersion"] && [searchFilters[@"mcVersion"] length] > 0) {
        params[@"gameVersion"] = searchFilters[@"mcVersion"];
    }
    
    NSDictionary *response = [self getEndpoint:@"mods/search" params:params];
    if (!response) {
        return nil;
    }
    
    NSArray *dataArray = response[@"data"];
    NSMutableArray *results = previousResults ? previousResults : [NSMutableArray array];
    
    // Update offset for next page
    self.previousOffset += dataArray.count;
    
    // Check if we've reached the end
    self.reachedLastPage = dataArray.count < limit;
    
    for (NSDictionary *modData in dataArray) {
        NSMutableDictionary *item = [@{
            @"apiSource": @(0),
            @"isModpack": @(isModpack),
            @"id": [modData[@"id"] stringValue],
            @"title": modData[@"name"] ?: @"",
            @"description": modData[@"summary"] ?: @"",
            @"imageUrl": modData[@"logo"] ? modData[@"logo"][@"thumbnailUrl"] : @""
        } mutableCopy];
        [results addObject:item];
    }
    
    self.lastSearchTerm = searchFilters[@"name"];
    return results;
}

- (void)installModpackFromDetail:(NSDictionary *)detail atIndex:(NSInteger)index {
    NSString *zipUrlString = detail[@"versionUrls"][index];
    if (!zipUrlString) {
        NSLog(@"No download URL available");
        return;
    }
    
    NSURL *zipUrl = [NSURL URLWithString:zipUrlString];
    NSString *destPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"modpack_install"];
    [[NSFileManager defaultManager] createDirectoryAtPath:destPath withIntermediateDirectories:YES attributes:nil error:nil];
    
    NSString *zipPath = [destPath stringByAppendingPathComponent:@"modpack.zip"];
    NSURLSessionDownloadTask *downloadTask = [[NSURLSession sharedSession] downloadTaskWithURL:zipUrl 
        completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
            if (error) {
                NSLog(@"Download failed: %@", error.localizedDescription);
                return;
            }
            
            [[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:zipPath] error:nil];
            
            NSError *archiveError = nil;
            UZKArchive *archive = [[UZKArchive alloc] initWithPath:zipPath error:&archiveError];
            if (archiveError) {
                NSLog(@"Failed to open modpack package: %@", archiveError.localizedDescription);
                return;
            }
            
            [archive extractFilesTo:destPath overwrite:YES error:&archiveError];
            if (archiveError) {
                NSLog(@"Failed to extract modpack: %@", archiveError.localizedDescription);
                return;
            }
            
            [[NSFileManager defaultManager] removeItemAtPath:zipPath error:nil];
            
            NSLog(@"Modpack installed successfully from CurseForge.");
        }];
    
    [downloadTask resume];
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    NSArray *response = [self getEndpoint:[NSString stringWithFormat:@"mods/%@", item[@"id"]] params:nil];
    if (!response) {
        return;
    }
    
    // Add implementation for loading mod details
    // Similar to ModrinthAPI's implementation but adapted for CurseForge's API structure
}

@end
