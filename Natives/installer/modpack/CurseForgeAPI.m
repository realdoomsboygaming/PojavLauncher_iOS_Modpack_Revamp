#import "CurseForgeAPI.h"
#import "UZKArchive.h"
#import "AFNetworking.h"

// Constants for CurseForge API
static const NSInteger kCurseForgeGameIDMinecraft = 432;
static const NSInteger kCurseForgeClassIDModpack = 4471;
static const NSInteger kCurseForgeClassIDMod = 6;

@implementation CurseForgeAPI

- (instancetype)init {
    NSString *apiKey = [self loadAPIKey]; // Load API Key securely
    return [self initWithAPIKey:apiKey];
}

- (instancetype)initWithAPIKey:(NSString *)apiKey {
    self = [super initWithURL:@"https://api.curseforge.com/v1"];
    if (self) {
        self.apiKey = apiKey;
        self.previousOffset = 0;
    }
    return self;
}

- (NSString *)loadAPIKey {
    NSDictionary *environment = [[NSProcessInfo processInfo] environment];
    NSString *apiKey = environment[@"CURSEFORGE_API_KEY"];
    if (!apiKey || [apiKey length] == 0) {
        NSLog(@"⚠️ WARNING: CurseForge API key is missing! Add CURSEFORGE_API_KEY to environment variables.");
    }
    return apiKey;
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
    
    if (searchFilters[@"mcVersion"] && [searchFilters[@"mcVersion"] length] > 0) {
        params[@"gameVersion"] = searchFilters[@"mcVersion"];
    }

    NSDictionary *response = [self getEndpoint:@"mods/search" params:params];
    if (!response) {
        return nil;
    }

    NSArray *dataArray = response[@"data"];
    NSMutableArray *results = previousResults ? previousResults : [NSMutableArray array];

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

    NSData *zipData = [NSData dataWithContentsOfURL:zipUrl];
    if (!zipData) {
        NSLog(@"Failed to download modpack zip");
        return;
    }

    NSString *zipPath = [destPath stringByAppendingPathComponent:@"modpack.zip"];
    [zipData writeToFile:zipPath atomically:YES];

    NSError *error = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:zipPath error:&error];
    if (error) {
        NSLog(@"Failed to open modpack package: %@", error.localizedDescription);
        return;
    }

    [archive extractFilesTo:destPath overwrite:YES error:&error];
    if (error) {
        NSLog(@"Failed to extract modpack: %@", error.localizedDescription);
        return;
    }

    [[NSFileManager defaultManager] removeItemAtPath:zipPath error:nil];

    NSLog(@"Modpack installed successfully from CurseForge.");
}

@end
