#import "modpack/CurseForgeAPI.h"
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
    
    // Safely extract search filter name
    NSString *searchName = ([searchFilters[@"name"] isKindOfClass:[NSString class]] ? searchFilters[@"name"] : @"");
    params[@"searchFilter"] = searchName;
    
    params[@"sortField"] = @(1);
    params[@"sortOrder"] = @"desc";
    
    int limit = 50;
    params[@"pageSize"] = @(limit);
    
    // Safely compare previous search term
    NSString *lastSearchName = ([self.lastSearchTerm isKindOfClass:[NSString class]] ? self.lastSearchTerm : @"");
    if (!previousResults || ![searchName isEqualToString:lastSearchName]) {
        self.previousOffset = 0;
        self.reachedLastPage = NO;
    }
    
    params[@"index"] = @(self.previousOffset);
    
    if (searchFilters[@"mcVersion"] && [searchFilters[@"mcVersion"] isKindOfClass:[NSString class]] && [searchFilters[@"mcVersion"] length] > 0) {
        params[@"gameVersion"] = searchFilters[@"mcVersion"];
    }
    
    NSDictionary *response = [self getEndpoint:@"mods/search" params:params];
    if (!response) return nil;
    
    NSArray *dataArray = response[@"data"];
    NSMutableArray *results = previousResults ? previousResults : [NSMutableArray array];
    self.previousOffset += dataArray.count;
    self.reachedLastPage = dataArray.count < limit;
    
    for (NSDictionary *modData in dataArray) {
        id modIdValue = modData[@"id"];
        NSString *modId = ([modIdValue respondsToSelector:@selector(stringValue)] ? [modIdValue stringValue] : @"");
        
        NSString *title = ([modData[@"name"] isKindOfClass:[NSString class]] ? modData[@"name"] : @"");
        NSString *summary = ([modData[@"summary"] isKindOfClass:[NSString class]] ? modData[@"summary"] : @"");
        
        NSDictionary *logoDict = ([modData[@"logo"] isKindOfClass:[NSDictionary class]] ? modData[@"logo"] : nil);
        NSString *imageUrl = (logoDict && [logoDict[@"thumbnailUrl"] isKindOfClass:[NSString class]] ? logoDict[@"thumbnailUrl"] : @"");
        
        NSMutableDictionary *item = [@{
            @"apiSource": @(0),
            @"isModpack": @(isModpack),
            @"id": modId,
            @"title": title,
            @"description": summary,
            @"imageUrl": imageUrl
        } mutableCopy];
        
        [self loadDetailsOfMod:item]; // Critical version data loading
        [results addObject:item];
    }
    
    self.lastSearchTerm = searchName;
    return results;
}

- (void)installModpackFromDetail:(NSDictionary *)detail atIndex:(NSInteger)index {
    NSString *zipUrlString = ([detail[@"versionUrls"] isKindOfClass:[NSArray class]] && index < [detail[@"versionUrls"] count] ? detail[@"versionUrls"][index] : nil);
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
        
        NSError *moveError = nil;
        [[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:zipPath] error:&moveError];
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
        
        [[NSFileManager defaultManager] removeItemAtPath:zipPath error:nil];
        NSLog(@"Modpack installed successfully from CurseForge.");
    }];
    
    [downloadTask resume];
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    NSString *modId = item[@"id"];
    if (!modId || [modId isEqualToString:@""]) return;
    
    NSDictionary *response = [self getEndpoint:[NSString stringWithFormat:@"mods/%@", modId] params:nil];
    if (!response || !response[@"data"]) return;
    
    NSArray *files = response[@"data"][@"latestFiles"];
    if (!files || ![files isKindOfClass:[NSArray class]]) return;

    NSMutableArray *versionNames = [NSMutableArray array];
    NSMutableArray *mcVersionNames = [NSMutableArray array];
    NSMutableArray *versionUrls = [NSMutableArray array];
    
    for (NSDictionary *file in files) {
        NSString *displayName = ([file[@"displayName"] isKindOfClass:[NSString class]] ? file[@"displayName"] : @"");
        [versionNames addObject:displayName];
        
        NSArray *gameVersions = ([file[@"gameVersions"] isKindOfClass:[NSArray class]] ? file[@"gameVersions"] : @[]);
        NSString *mcVersion = (gameVersions.count > 0 ? gameVersions.firstObject : @"");
        [mcVersionNames addObject:mcVersion];
        
        id fileIdValue = file[@"id"];
        NSString *fileId = ([fileIdValue respondsToSelector:@selector(stringValue)] ? [fileIdValue stringValue] : @"");
        NSString *downloadUrl = ([file[@"downloadUrl"] isKindOfClass:[NSString class]] ? file[@"downloadUrl"] : @"");
        
        if (downloadUrl.length == 0 && fileId.length >= 4) {
            NSString *fileName = ([file[@"fileName"] isKindOfClass:[NSString class]] ? file[@"fileName"] : @"");
            downloadUrl = [NSString stringWithFormat:@"https://edge.forgecdn.net/files/%@/%@/%@",
                           [fileId substringToIndex:4],
                           [fileId substringWithRange:NSMakeRange(4, 2)],
                           fileName];
        }
        
        [versionUrls addObject:downloadUrl];
    }
    
    item[@"versionNames"] = versionNames;
    item[@"mcVersionNames"] = mcVersionNames;
    item[@"versionUrls"] = versionUrls;
}

@end
