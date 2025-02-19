#import "CurseForgeAPI.h"
#import "UZKArchive.h"
#import "AFNetworking.h"

// Constants for CurseForge API
static const NSInteger kCurseForgeGameIDMinecraft = 432;
static const NSInteger kCurseForgeClassIDModpack = 4471;
static const NSInteger kCurseForgeClassIDMod = 6;

@implementation CurseForgeAPI

- (instancetype)initWithAPIKey:(NSString *)apiKey {
    self = [super initWithURL:@"https://api.curseforge.com/v1"];
    if (self) {
        self.apiKey = apiKey;
        self.previousOffset = 0;
    }
    return self;
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
    NSInteger pageSize = 50;
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
    
    if (previousResults) {
        params[@"index"] = @(self.previousOffset);
    }

    NSDictionary *response = [self getEndpoint:@"mods/search" params:params];
    if (!response) {
        return nil;
    }

    NSArray *dataArray = response[@"data"];
    NSDictionary *paginationInfo = response[@"pagination"];
    NSMutableArray *results = previousResults ? previousResults : [NSMutableArray array];

    for (NSDictionary *modData in dataArray) {
        if (modData[@"allowModDistribution"] && ![modData[@"allowModDistribution"] boolValue]) {
            NSLog(@"Skipping modpack %@ because distribution not allowed", modData[@"name"]);
            continue;
        }
        NSMutableDictionary *item = [@{
            @"apiSource": @(0), // 0 = CurseForge
            @"isModpack": @(isModpack),
            @"id": [modData[@"id"] stringValue],
            @"title": modData[@"name"] ?: @"",
            @"description": modData[@"summary"] ?: @"",
            @"imageUrl": modData[@"logo"] ? modData[@"logo"][@"thumbnailUrl"] : @""
        } mutableCopy];
        [results addObject:item];
    }
    self.previousOffset += dataArray.count;
    self.reachedLastPage = (results.count >= [paginationInfo[@"totalCount"] integerValue]);

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

    NSData *manifestData = [archive extractDataFromFile:@"manifest.json" error:&error];
    if (error || !manifestData) {
        NSLog(@"Failed to extract manifest.json: %@", error.localizedDescription);
        return;
    }
    NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:&error];
    if (error || !manifest) {
        NSLog(@"Failed to parse manifest.json: %@", error.localizedDescription);
        return;
    }

    if (![self verifyManifest:manifest]) {
        NSLog(@"Manifest verification failed");
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

- (BOOL)verifyManifest:(NSDictionary *)manifest {
    return ([manifest[@"manifestType"] isEqualToString:@"minecraftModpack"]
        && [manifest[@"manifestVersion"] integerValue] == 1
        && manifest[@"minecraft"]
        && manifest[@"minecraft"][@"version"]
        && manifest[@"minecraft"][@"modLoaders"] && [manifest[@"minecraft"][@"modLoaders"] count] > 0);
}

@end
