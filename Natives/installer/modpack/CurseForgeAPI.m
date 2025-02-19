#import "CurseForgeAPI.h"
#import "utils.h"
#import "UZKArchive.h"
#import "ModpackUtils.h"

static const NSInteger kCurseForgeGameIDMinecraft = 432;
static const NSInteger kCurseForgeClassIDModpack  = 4471;
static const NSInteger kCurseForgeClassIDMod      = 6;

@implementation CurseForgeAPI

#pragma mark - Init & API Key

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

#pragma mark - Endpoint Request

- (id)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params {
    __block id result = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    
    NSURLComponents *components = [NSURLComponents componentsWithString:
       [NSString stringWithFormat:@"https://api.curseforge.com/v1/%@", endpoint]];
    
    // Build query
    if ([params isKindOfClass:[NSDictionary class]]) {
        NSMutableArray<NSURLQueryItem *> *queryItems = [NSMutableArray array];
        for (NSString *key in params) {
            [queryItems addObject:[NSURLQueryItem queryItemWithName:key value:[NSString stringWithFormat:@"%@", params[key]]]];
        }
        components.queryItems = queryItems;
    }
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL];
    [request setValue:self.apiKey forHTTPHeaderField:@"x-api-key"];
    [request setValue:@"Mozilla/5.0" forHTTPHeaderField:@"User-Agent"];
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error)
    {
        if (error) {
            self.lastError = error;
            dispatch_semaphore_signal(semaphore);
            return;
        }
        
        NSError *jsonError = nil;
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError) {
            self.lastError = jsonError;
        } else {
            result = parsed;
        }
        dispatch_semaphore_signal(semaphore);
    }];
    
    [task resume];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    return result;
}

#pragma mark - Searching

- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, id> *)searchFilters
                      previousPageResult:(NSMutableArray *)previousResults
{
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    params[@"gameId"] = @(kCurseForgeGameIDMinecraft);
    
    BOOL isModpack = [searchFilters[@"isModpack"] boolValue];
    params[@"classId"] = isModpack ? @(kCurseForgeClassIDModpack) : @(kCurseForgeClassIDMod);
    
    // Safely extract "name"
    NSString *searchName = ([searchFilters[@"name"] isKindOfClass:[NSString class]] ? searchFilters[@"name"] : @"");
    params[@"searchFilter"] = searchName;
    
    params[@"sortField"] = @(1);
    params[@"sortOrder"] = @"desc";
    
    int limit = 50;
    params[@"pageSize"] = @(limit);
    
    // Check if new search
    NSString *lastSearchName = ([self.lastSearchTerm isKindOfClass:[NSString class]] ? self.lastSearchTerm : @"");
    if (!previousResults || ![searchName isEqualToString:lastSearchName]) {
        self.previousOffset = 0;
        self.reachedLastPage = NO;
    }
    
    params[@"index"] = @(self.previousOffset);
    
    // Optionally specify a Minecraft version
    if ([searchFilters[@"mcVersion"] isKindOfClass:[NSString class]] &&
        [searchFilters[@"mcVersion"] length] > 0)
    {
        params[@"gameVersion"] = searchFilters[@"mcVersion"];
    }
    
    NSDictionary *response = [self getEndpoint:@"mods/search" params:params];
    if (!response || ![response[@"data"] isKindOfClass:[NSArray class]]) {
        return nil; // self.lastError presumably set
    }
    
    NSArray *dataArray = response[@"data"];
    NSMutableArray *results = previousResults ?: [NSMutableArray array];
    
    self.previousOffset += dataArray.count;
    self.reachedLastPage = dataArray.count < limit;
    
    for (NSDictionary *modData in dataArray) {
        id modIdValue = modData[@"id"];
        NSString *modId = [modIdValue respondsToSelector:@selector(stringValue)]
                          ? [modIdValue stringValue] : @"";
        
        NSString *title   = ([modData[@"name"] isKindOfClass:[NSString class]]    ? modData[@"name"]    : @"");
        NSString *summary = ([modData[@"summary"] isKindOfClass:[NSString class]] ? modData[@"summary"] : @"");
        
        NSDictionary *logoDict = ([modData[@"logo"] isKindOfClass:[NSDictionary class]] ? modData[@"logo"] : nil);
        NSString *imageUrl = (logoDict && [logoDict[@"thumbnailUrl"] isKindOfClass:[NSString class]]
                              ? logoDict[@"thumbnailUrl"]
                              : @"");
        
        NSMutableDictionary *item = [@{
            @"apiSource": @(0),
            @"isModpack": @(isModpack),
            @"id": modId,
            @"title": title,
            @"description": summary,
            @"imageUrl": imageUrl
        } mutableCopy];
        
        // Load version data right away
        [self loadDetailsOfMod:item];
        [results addObject:item];
    }
    
    self.lastSearchTerm = searchName;
    return results;
}

#pragma mark - Installing

- (void)installModpackFromDetail:(NSDictionary *)detail atIndex:(NSInteger)index {
    // Make sure detail has versionUrls array
    if (![detail[@"versionUrls"] isKindOfClass:[NSArray class]]) {
        return;
    }
    if (index >= [detail[@"versionUrls"] count]) {
        return;
    }
    
    NSString *zipUrlString = detail[@"versionUrls"][index];
    if (!zipUrlString.length) {
        return;
    }
    
    NSURL *zipUrl = [NSURL URLWithString:zipUrlString];
    NSString *destPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"modpack_install"];
    [[NSFileManager defaultManager] createDirectoryAtPath:destPath
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    
    NSString *zipPath = [destPath stringByAppendingPathComponent:@"modpack.zip"];
    NSURLSessionDownloadTask *downloadTask = [[NSURLSession sharedSession]
       downloadTaskWithURL:zipUrl
         completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error)
    {
        if (error) {
            NSLog(@"[CurseForgeAPI] Download error: %@", error.localizedDescription);
            return;
        }
        
        NSError *moveError = nil;
        [[NSFileManager defaultManager] moveItemAtURL:location
                                                toURL:[NSURL fileURLWithPath:zipPath]
                                                error:&moveError];
        if (moveError) {
            NSLog(@"Error moving downloaded file: %@", moveError.localizedDescription);
            return;
        }
        
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
        
        // Remove the original zip
        [[NSFileManager defaultManager] removeItemAtPath:zipPath error:nil];
        NSLog(@"Modpack installed successfully from CurseForge.");
    }];
    
    [downloadTask resume];
}

#pragma mark - Loading Details

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    NSString *modId = item[@"id"];
    if (!modId.length) {
        return;
    }
    
    NSDictionary *response = [self getEndpoint:[NSString stringWithFormat:@"mods/%@", modId]
                                        params:nil];
    if (!response || ![response[@"data"] isKindOfClass:[NSDictionary class]]) {
        return;
    }
    
    NSDictionary *data = response[@"data"];
    NSArray *files = data[@"latestFiles"];
    if (![files isKindOfClass:[NSArray class]]) {
        return;
    }
    
    NSMutableArray *versionNames    = [NSMutableArray array];
    NSMutableArray *mcVersionNames  = [NSMutableArray array];
    NSMutableArray *versionUrls     = [NSMutableArray array];
    
    for (NSDictionary *file in files) {
        // Display name
        NSString *displayName = ([file[@"displayName"] isKindOfClass:[NSString class]]
                                 ? file[@"displayName"]
                                 : @"");
        [versionNames addObject:displayName];
        
        // Minecraft version(s)
        NSArray *gameVersions = ([file[@"gameVersions"] isKindOfClass:[NSArray class]]
                                 ? file[@"gameVersions"]
                                 : @[]);
        NSString *mcVersion = (gameVersions.count > 0 ? gameVersions.firstObject : @"");
        [mcVersionNames addObject:mcVersion];
        
        // Download URL
        id fileIdValue = file[@"id"];
        NSString *fileId = ([fileIdValue respondsToSelector:@selector(stringValue)]
                            ? [fileIdValue stringValue]
                            : @"");
        NSString *downloadUrl = ([file[@"downloadUrl"] isKindOfClass:[NSString class]]
                                 ? file[@"downloadUrl"]
                                 : @"");
        
        // If no direct downloadUrl, build it from the file ID
        if (downloadUrl.length == 0 && fileId.length >= 4) {
            NSString *fileName = ([file[@"fileName"] isKindOfClass:[NSString class]]
                                  ? file[@"fileName"]
                                  : @"");
            // Common pattern for CF
            downloadUrl = [NSString stringWithFormat:@"https://edge.forgecdn.net/files/%@/%@/%@",
                           [fileId substringToIndex:4],
                           [fileId substringWithRange:NSMakeRange(4, 2)],
                           fileName];
        }
        
        [versionUrls addObject:downloadUrl ?: @""];
    }
    
    item[@"versionNames"] = versionNames;
    item[@"mcVersionNames"] = mcVersionNames;
    item[@"versionUrls"] = versionUrls;
}

@end
