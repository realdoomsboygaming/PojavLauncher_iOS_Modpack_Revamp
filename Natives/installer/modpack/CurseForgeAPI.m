#import "CurseForgeAPI.h"
#import "AFNetworking.h"
#import "ModpackUtils.h"
#import "MinecraftResourceDownloadTask.h"
#import "PLProfiles.h"

@implementation CurseForgeAPI

- (instancetype)init {
    self = [super initWithURL:@"https://api.curseforge.com"];
    return self;
}

// Override getEndpoint to include CurseForge API key
- (id)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params {
    __block id result;
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);
    NSString *url = [self.baseURL stringByAppendingPathComponent:endpoint];
    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    NSString *apiKey = [[NSUserDefaults standardUserDefaults] objectForKey:@"CurseForgeAPIKey"];
    if (apiKey) {
        [manager.requestSerializer setValue:apiKey forHTTPHeaderField:@"x-api-key"];
    }
    [manager GET:url parameters:params headers:nil progress:nil success:^(NSURLSessionTask *task, id responseObject) {
        result = responseObject;
        dispatch_group_leave(group);
    } failure:^(NSURLSessionTask *task, NSError *error) {
        self.lastError = error;
        dispatch_group_leave(group);
    }];
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    return result;
}

- (NSMutableArray *)searchModWithFilters:(NSDictionary *)searchFilters previousPageResult:(NSMutableArray *)prevResult {
    int limit = 50;
    NSString *query = searchFilters[@"name"] ?: @"";
    NSDictionary *params = @{
        @"gameId": @(kCurseForgeGameIDMinecraft),
        @"classId": @(kCurseForgeClassIDModpack),
        @"searchFilter": query,
        @"pageSize": @(limit),
        @"index": @(prevResult.count)
    };
    NSDictionary *response = [self getEndpoint:@"v1/mods/search" params:params];
    if (!response) {
        return nil;
    }
    NSMutableArray *result = prevResult ?: [NSMutableArray new];
    NSArray *data = response[@"data"];
    for (NSDictionary *mod in data) {
        [result addObject:[@{
            @"apiSource": @(2),
            @"isModpack": @(YES),
            @"id": mod[@"id"],
            @"title": mod[@"name"],
            @"description": mod[@"summary"] ?: @"",
            @"imageUrl": mod[@"logo"] ?: @""
        } mutableCopy]];
    }
    NSInteger totalCount = [response[@"pagination"][@"totalCount"] integerValue];
    self.reachedLastPage = (result.count >= totalCount);
    return result;
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    NSString *endpoint = [NSString stringWithFormat:@"v1/mods/%@/files", item[@"id"]];
    NSDictionary *response = [self getEndpoint:endpoint params:nil];
    if (!response) {
        return;
    }
    NSArray *files = response[@"data"];
    NSMutableArray *names = [NSMutableArray new];
    NSMutableArray *mcNames = [NSMutableArray new];
    NSMutableArray *sizes = [NSMutableArray new];
    NSMutableArray *urls = [NSMutableArray new];
    NSMutableArray *hashes = [NSMutableArray new];
    [files enumerateObjectsUsingBlock:^(NSDictionary *file, NSUInteger i, BOOL *stop) {
        NSString *fileName = file[@"fileName"] ?: @"";
        [names addObject:fileName];
        NSString *gameVersion = file[@"gameVersion"] ?: @"";
        [mcNames addObject:gameVersion];
        NSNumber *fileSize = file[@"fileLength"] ?: @(0);
        [sizes addObject:fileSize];
        NSString *downloadUrl = file[@"downloadUrl"] ?: @"";
        [urls addObject:downloadUrl];
        NSDictionary *hashesMap = file[@"hashes"];
        NSString *sha1 = hashesMap[@"sha1"] ?: [NSNull null];
        [hashes addObject:sha1];
    }];
    item[@"versionNames"] = names;
    item[@"mcVersionNames"] = mcNames;
    item[@"versionSizes"] = sizes;
    item[@"versionUrls"] = urls;
    item[@"versionHashes"] = hashes;
    item[@"versionDetailsLoaded"] = @(YES);
}

- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath {
    NSError *error;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to open modpack package: %@", error.localizedDescription]];
        return;
    }
    NSData *indexData = [archive extractDataFromFile:@"curseforge.index.json" error:&error];
    NSDictionary *indexDict = [NSJSONSerialization JSONObjectWithData:indexData options:kNilOptions error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to parse curseforge.index.json: %@", error.localizedDescription]];
        return;
    }
    downloader.progress.totalUnitCount = [indexDict[@"files"] count];
    for (NSDictionary *indexFile in indexDict[@"files"]) {
        NSString *url = [indexFile[@"downloads"] firstObject];
        NSString *sha = indexFile[@"hashes"][@"sha1"];
        NSString *path = [destPath stringByAppendingPathComponent:indexFile[@"path"]];
        NSUInteger size = [indexFile[@"fileSize"] unsignedLongLongValue];
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:url size:size sha:sha altName:nil toPath:path];
        if (task) {
            [downloader.fileList addObject:indexFile[@"path"]];
            [task resume];
        } else if (!downloader.progress.cancelled) {
            downloader.progress.completedUnitCount++;
        } else {
            return;
        }
    }
    [ModpackUtils archive:archive extractDirectory:@"overrides" toPath:destPath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract overrides from modpack package: %@", error.localizedDescription]];
        return;
    }
    [ModpackUtils archive:archive extractDirectory:@"client-overrides" toPath:destPath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract client-overrides from modpack package: %@", error.localizedDescription]];
        return;
    }
    [NSFileManager.defaultManager removeItemAtPath:packagePath error:nil];
    NSDictionary<NSString *, NSString *> *depInfo = [ModpackUtils infoForDependencies:indexDict[@"dependencies"]];
    if (depInfo[@"json"]) {
        NSString *jsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), depInfo[@"id"]];
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:depInfo[@"json"] size:0 sha:nil altName:nil toPath:jsonPath];
        [task resume];
    }
    NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
    PLProfiles.current.profiles[indexDict[@"name"]] = [@{
        @"gameDir": [NSString stringWithFormat:@"./custom_gamedir/%@", destPath.lastPathComponent],
        @"name": indexDict[@"name"],
        @"lastVersionId": depInfo[@"id"],
        @"icon": [NSString stringWithFormat:@"data:image/png;base64,%@",
                  [[NSData dataWithContentsOfFile:tmpIconPath] base64EncodedStringWithOptions:0]]
    } mutableCopy];
    PLProfiles.current.selectedProfileName = indexDict[@"name"];
}

- (void)installModpackFromDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion {
    NSDictionary *userInfo = @{
        @"detail": modDetail,
        @"index": @(selectedVersion)
    };
    [NSNotificationCenter.defaultCenter postNotificationName:@"InstallModpack" object:self userInfo:userInfo];
}

@end
