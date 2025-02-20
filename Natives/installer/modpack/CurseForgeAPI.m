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

@implementation CurseForgeAPI

- (instancetype)init {
    // Set the base URL to CurseForge’s v1 API
    return [super initWithURL:@"https://api.curseforge.com/v1"];
}

#pragma mark - Overridden GET Endpoint

// Override to add the required API key header using the secret provided via environment variable
- (id)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params {
    __block id result;
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);
    NSString *url = [self.baseURL stringByAppendingPathComponent:endpoint];
    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    
    // Use the API key from config.h if defined, otherwise fallback to the environment variable
    NSString *apiKey = CONFIG_CURSEFORGE_API_KEY;
    if (apiKey.length == 0) {
        char *envKey = getenv("CURSEFORGE_API_KEY");
        if (envKey) {
            apiKey = [NSString stringWithUTF8String:envKey];
        }
    }
    [manager.requestSerializer setValue:apiKey forHTTPHeaderField:@"x-api-key"];
    
    [manager GET:url parameters:params headers:nil progress:nil
         success:^(NSURLSessionTask *task, id obj) {
             result = obj;
             dispatch_group_leave(group);
         }
         failure:^(NSURLSessionTask *operation, NSError *error) {
             self.lastError = error;
             dispatch_group_leave(group);
         }];
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    return result;
}

#pragma mark - Search Modpacks

- (NSMutableArray *)searchModWithFilters:(NSDictionary *)searchFilters previousPageResult:(NSMutableArray *)prevResult {
    int limit = 50;
    NSString *query = searchFilters[@"name"] ?: @"";
    
    // Build parameters using CurseForge-specific keys
    NSMutableDictionary *params = [@{
        @"gameId": @(kCurseForgeGameIDMinecraft),
        @"classId": (searchFilters[@"isModpack"] && [searchFilters[@"isModpack"] boolValue]) ? @(kCurseForgeClassIDModpack) : @(kCurseForgeClassIDMod),
        @"searchFilter": query,
        @"pageSize": @(limit),
        @"index": @(prevResult.count)
    } mutableCopy];
    
    if (searchFilters[@"mcVersion"] && [searchFilters[@"mcVersion"] length] > 0) {
        params[@"gameVersion"] = searchFilters[@"mcVersion"];
    }
    
    NSDictionary *response = [self getEndpoint:@"mods/search" params:params];
    if (!response) {
        return nil;
    }
    
    // Initialize or append to the result array
    NSMutableArray *result = prevResult ?: [NSMutableArray new];
    NSArray *data = response[@"data"]; // CurseForge returns mods in the "data" array
    for (NSDictionary *mod in data) {
        BOOL isModpack = ([mod[@"classId"] integerValue] == kCurseForgeClassIDModpack);
        NSMutableDictionary *entry = [@{
            @"apiSource": @(0), // Use 0 for CurseForge and 1 for Modrinth
            @"isModpack": @(isModpack),
            @"id": mod[@"id"],
            @"title": mod[@"name"],
            @"description": mod[@"summary"] ?: @"",
            @"imageUrl": mod[@"logo"] ?: @""
        } mutableCopy];
        [result addObject:entry];
    }
    
    // Update pagination: assume the response includes a "pagination" dictionary with totalCount
    NSDictionary *pagination = response[@"pagination"];
    NSUInteger totalCount = [pagination[@"totalCount"] unsignedIntegerValue];
    self.reachedLastPage = (result.count >= totalCount);
    return result;
}

#pragma mark - Load Mod Details

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    NSString *modId = [NSString stringWithFormat:@"%@", item[@"id"]];
    // Fetch file details for the mod using the CurseForge endpoint
    NSDictionary *response = [self getEndpoint:[NSString stringWithFormat:@"mods/%@/files", modId] params:nil];
    if (!response) {
        return;
    }
    NSArray *files = response[@"data"];
    // Prepare arrays to hold version details
    NSMutableArray *names = [NSMutableArray new];
    NSMutableArray *mcNames = [NSMutableArray new];
    NSMutableArray *urls = [NSMutableArray new];
    NSMutableArray *hashes = [NSMutableArray new];
    NSMutableArray *sizes = [NSMutableArray new];
    
    [files enumerateObjectsUsingBlock:^(NSDictionary *file, NSUInteger i, BOOL *stop) {
        // Use the file name as version name
        [names addObject:file[@"fileName"] ?: @""];
        
        // For CurseForge, game version might be provided in "gameVersion" or "gameVersionList"
        id versions = file[@"gameVersion"] ?: file[@"gameVersionList"];
        NSString *gameVersion = @"";
        if ([versions isKindOfClass:[NSArray class]] && [versions count] > 0) {
            gameVersion = versions[0];
        } else if ([versions isKindOfClass:[NSString class]]) {
            gameVersion = versions;
        }
        [mcNames addObject:gameVersion];
        
        // Download URL and file size
        [urls addObject:file[@"downloadUrl"] ?: @""];
        [sizes addObject:[NSString stringWithFormat:@"%@", file[@"fileLength"] ?: @"0"]];
        
        // Extract the SHA1 hash from the "hashes" array (if available)
        NSString *sha1 = @"";
        NSArray *hashesArray = file[@"hashes"];
        for (NSDictionary *hashDict in hashesArray) {
            if ([hashDict[@"algo"] isEqualToString:@"SHA1"]) {
                sha1 = hashDict[@"value"];
                break;
            }
        }
        [hashes addObject:sha1];
    }];
    
    // Populate the mod item dictionary with version details
    item[@"versionNames"] = names;
    item[@"mcVersionNames"] = mcNames;
    item[@"versionSizes"] = sizes;
    item[@"versionUrls"] = urls;
    item[@"versionHashes"] = hashes;
    item[@"versionDetailsLoaded"] = @(YES);
}

#pragma mark - Download and Process Modpack Package

- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath {
    NSError *error = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to open modpack package: %@", error.localizedDescription]];
        return;
    }
    
    // Try to extract the CurseForge-specific index file; if not present, fall back to modrinth.index.json
    NSData *indexData = [archive extractDataFromFile:@"curseforge.index.json" error:&error];
    if (!indexData) {
        indexData = [archive extractDataFromFile:@"modrinth.index.json" error:&error];
    }
    
    NSDictionary *indexDict = [NSJSONSerialization JSONObjectWithData:indexData options:kNilOptions error:&error];
    if (error || !indexDict) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to parse modpack index JSON: %@", error.localizedDescription]];
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
            return; // cancelled
        }
    }
    
    // Extract any overrides and client-overrides directories
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
    
    // Remove the temporary package file
    [NSFileManager.defaultManager removeItemAtPath:packagePath error:nil];
    
    // Process dependency information if available
    NSDictionary<NSString *, NSString *> *depInfo = [ModpackUtils infoForDependencies:indexDict[@"dependencies"]];
    if (depInfo[@"json"]) {
        NSString *jsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), depInfo[@"id"]];
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:depInfo[@"json"] size:0 sha:nil altName:nil toPath:jsonPath];
        [task resume];
    }
    
    // Create a new profile using the extracted modpack data
    NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
    PLProfiles.current.profiles[indexDict[@"name"]] = @{
        @"gameDir": [NSString stringWithFormat:@"./custom_gamedir/%@", destPath.lastPathComponent],
        @"name": indexDict[@"name"],
        @"lastVersionId": depInfo[@"id"],
        @"icon": [NSString stringWithFormat:@"data:image/png;base64,%@",
                   [[NSData dataWithContentsOfFile:tmpIconPath] base64EncodedStringWithOptions:0]]
    }.mutableCopy;
    PLProfiles.current.selectedProfileName = indexDict[@"name"];
}

@end
