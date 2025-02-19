#import "CurseForgeAPI.h"
#import "utils.h"
#import "UZKArchive.h"
#import "ModpackUtils.h"

static const NSInteger kCurseForgeGameIDMinecraft = 432;
static const NSInteger kCurseForgeClassIDModpack = 4471;
static const NSInteger kCurseForgeClassIDMod = 6;

@implementation CurseForgeAPI

- (instancetype)initWithAPIKey:(NSString *)apiKey {
    self = [super init];
    if (self) {
        _apiKey = apiKey;
        _previousOffset = 0;
    }
    return self;
}

- (NSString *)loadAPIKey {
    NSDictionary *environment = [[NSProcessInfo processInfo] environment];
    NSString *envKey = environment[@"CURSEFORGE_API_KEY"];
    if (!envKey || envKey.length == 0) {
        NSLog(@"⚠️ WARNING: CurseForge API key missing!");
    }
    return envKey;
}

- (id)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params {
    __block id result;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    NSURLComponents *components = [NSURLComponents componentsWithString:[NSString stringWithFormat:@"https://api.curseforge.com/v1/%@", endpoint]];
    components.queryItems = [self queryItemsFromParams:params];
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL];
    [request setValue:self.apiKey forHTTPHeaderField:@"x-api-key"];
    [request setValue:@"Mozilla/5.0" forHTTPHeaderField:@"User-Agent"];
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            self.lastError = error;
            dispatch_semaphore_signal(semaphore);
            return;
        }
        
        NSError *jsonError;
        result = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:&jsonError];
        if (jsonError) {
            self.lastError = jsonError;
        }
        dispatch_semaphore_signal(semaphore);
    }];
    
    [task resume];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    return result;
}

- (NSArray<NSURLQueryItem *> *)queryItemsFromParams:(NSDictionary *)params {
    NSMutableArray *queryItems = [NSMutableArray array];
    for (NSString *key in params) {
        [queryItems addObject:[NSURLQueryItem queryItemWithName:key value:[NSString stringWithFormat:@"%@", params[key]]]];
    }
    return queryItems;
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
    
    NSString *searchFilterName = ([searchFilters[@"name"] isKindOfClass:[NSString class]] ? searchFilters[@"name"] : @"");
    NSString *lastSearchName = ([self.lastSearchTerm isKindOfClass:[NSString class]] ? self.lastSearchTerm : @"");
    if (!previousResults || ![searchFilterName isEqualToString:lastSearchName]) {
        self.previousOffset = 0;
        self.reachedLastPage = NO;
    }

    
    params[@"index"] = @(self.previousOffset);
    
    if (searchFilters[@"mcVersion"] && [searchFilters[@"mcVersion"] length] > 0) {
        params[@"gameVersion"] = searchFilters[@"mcVersion"];
    }
    
    NSDictionary *response = [self getEndpoint:@"mods/search" params:params];
    if (!response) return nil;
    
    NSArray *dataArray = response[@"data"];
    NSMutableArray *results = previousResults ? previousResults : [NSMutableArray array];
    self.previousOffset += dataArray.count;
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
        
        [self loadDetailsOfMod:item]; // Critical version data loading
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
    NSURLSessionDownloadTask *downloadTask = [[NSURLSession sharedSession] downloadTaskWithURL:zipUrl completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
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
    NSString *modId = item[@"id"];
    if (!modId) return;
    
    NSDictionary *response = [self getEndpoint:[NSString stringWithFormat:@"mods/%@", modId] params:nil];
    if (!response || !response[@"data"]) return;
    
    NSArray *files = response[@"data"][@"latestFiles"];
    if (!files || ![files isKindOfClass:[NSArray class]]) return;

    NSMutableArray *versionNames = [NSMutableArray array];
    NSMutableArray *mcVersionNames = [NSMutableArray array];
    NSMutableArray *versionUrls = [NSMutableArray array];
    
    for (NSDictionary *file in files) {
        // Version name
        NSString *displayName = file[@"displayName"] ?: @"";
        [versionNames addObject:displayName];
        
        // Minecraft version
        NSArray *gameVersions = file[@"gameVersions"];
        NSString *mcVersion = (gameVersions.count > 0) ? gameVersions.firstObject : @"";
        [mcVersionNames addObject:mcVersion];
        
        // Download URL
        NSString *fileId = [file[@"id"] stringValue];
        NSString *downloadUrl = file[@"downloadUrl"];
        
        if (!downloadUrl || [downloadUrl isEqualToString:@""]) {
            // Construct URL if not provided
            if (fileId.length >= 4) {
                downloadUrl = [NSString stringWithFormat:@"https://edge.forgecdn.net/files/%@/%@/%@",
                             [fileId substringToIndex:4],
                             [fileId substringWithRange:NSMakeRange(4, 2)],
                             file[@"fileName"]];
            }
        }
        
        [versionUrls addObject:downloadUrl ?: @""];
    }
    
    item[@"versionNames"] = versionNames;
    item[@"mcVersionNames"] = mcVersionNames;
    item[@"versionUrls"] = versionUrls;
}

@end
