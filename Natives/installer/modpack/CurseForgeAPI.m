#import "CurseForgeAPI.h"
#import "UZKArchive.h"

// Constants matching the CurseForge API (from the Android implementation)
static const NSInteger kCurseForgeGameIDMinecraft = 432;
static const NSInteger kCurseForgeClassIDModpack = 4471;
static const NSInteger kCurseForgeClassIDMod = 6;

@implementation CurseForgeAPI

@dynamic lastError;
@dynamic reachedLastPage;

- (instancetype)init {
    self = [super initWithURL:@"https://api.curseforge.com/v1"];
    if (self) {
        // No API key is required now.
        self.previousOffset = 0;
    }
    return self;
}

- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, id> *)searchFilters previousPageResult:(NSMutableArray *)previousResults {
    NSInteger pageSize = 50;
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    params[@"gameId"] = @(kCurseForgeGameIDMinecraft);
    BOOL isModpack = [searchFilters[@"isModpack"] boolValue];
    params[@"classId"] = isModpack ? @(kCurseForgeClassIDModpack) : @(kCurseForgeClassIDMod);
    params[@"searchFilter"] = searchFilters[@"name"];
    params[@"sortField"] = @(1); // Sort by relevancy
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
        id allowModDistribution = modData[@"allowModDistribution"];
        if (allowModDistribution && ![allowModDistribution boolValue]) {
            NSLog(@"Skipping modpack %@ because distribution not allowed", modData[@"name"]);
            continue;
        }
        NSMutableDictionary *item = [@{
            @"apiSource": @(0), // 0 indicates CurseForge
            @"isModpack": @(isModpack),
            @"id": [modData[@"id"] stringValue],
            @"title": modData[@"name"] ?: @"",
            @"description": modData[@"summary"] ?: @"",
            @"imageUrl": modData[@"logo"] ? modData[@"logo"][@"thumbnailUrl"] : @""
        } mutableCopy];
        [results addObject:item];
    }
    self.previousOffset += dataArray.count;
    NSInteger totalCount = [paginationInfo[@"totalCount"] integerValue];
    self.reachedLastPage = (results.count >= totalCount);
    return results;
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    NSMutableArray *allDetails = [NSMutableArray array];
    NSInteger index = 0;
    // Continue paginating until no more details are available.
    while (index != -1 && index != -2) {
        index = [self getPaginatedDetails:allDetails index:index modId:item[@"id"]];
    }
    if (index == -2) {
        // Optionally, set self.lastError here.
        return;
    }
    
    NSInteger count = allDetails.count;
    NSMutableArray *versionNames = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray *mcVersionNames = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray *versionUrls = [NSMutableArray arrayWithCapacity:count];
    NSMutableArray *hashes = [NSMutableArray arrayWithCapacity:count];
    
    NSError *regexError = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"([0-9]+)\\.([0-9]+)\\.?([0-9]+)?" options:0 error:&regexError];
    
    for (NSDictionary *detail in allDetails) {
        NSString *displayName = detail[@"displayName"];
        [versionNames addObject:displayName ?: @""];
        
        NSString *downloadUrl = detail[@"downloadUrl"];
        [versionUrls addObject:downloadUrl ?: @""];
        
        NSArray *gameVersions = detail[@"gameVersions"];
        NSString *mcVersion = @"";
        for (NSString *ver in gameVersions) {
            NSTextCheckingResult *match = [regex firstMatchInString:ver options:0 range:NSMakeRange(0, ver.length)];
            if (match) {
                mcVersion = ver;
                break;
            }
        }
        [mcVersionNames addObject:mcVersion];
        
        NSString *sha = [self getSha1FromModData:detail];
        [hashes addObject:sha ?: [NSNull null]];
    }
    
    item[@"versionNames"] = versionNames;
    item[@"mcVersionNames"] = mcVersionNames;
    item[@"versionUrls"] = versionUrls;
    item[@"versionHashes"] = hashes;
    item[@"versionDetailsLoaded"] = @(YES);
}

- (NSInteger)getPaginatedDetails:(NSMutableArray *)details index:(NSInteger)index modId:(NSString *)modId {
    NSInteger pageSize = 50;
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    params[@"index"] = @(index);
    params[@"pageSize"] = @(pageSize);
    NSString *endpoint = [NSString stringWithFormat:@"mods/%@/files", modId];
    NSDictionary *response = [self getEndpoint:endpoint params:params];
    NSArray *data = response[@"data"];
    if (!data) return -2;
    
    for (NSDictionary *fileInfo in data) {
        if ([fileInfo[@"isServerPack"] boolValue]) continue;
        [details addObject:fileInfo];
    }
    if (data.count < pageSize) return -1;
    return index + data.count;
}

- (NSString *)getSha1FromModData:(NSDictionary *)data {
    NSArray *hashes = data[@"hashes"];
    for (NSDictionary *hashInfo in hashes) {
        if ([hashInfo[@"algo"] integerValue] == 1) { // 1 indicates SHA-1
            return hashInfo[@"value"];
        }
    }
    return nil;
}

// Helper method using UZKArchive's available methods:
// It lists filenames using 'listFilenamesWithError:' and then extracts each file via 'extractFile:toPath:error:'
- (BOOL)extractDirectory:(NSString *)directory fromArchive:(UZKArchive *)archive toPath:(NSString *)destPath error:(NSError **)error {
    NSArray *filenames = [archive listFilenamesWithError:error];
    if (!filenames) {
        return NO;
    }
    BOOL success = YES;
    for (NSString *filename in filenames) {
        if ([filename hasPrefix:directory]) {
            NSString *fullPath = [destPath stringByAppendingPathComponent:filename];
            NSString *directoryPath = [fullPath stringByDeletingLastPathComponent];
            [[NSFileManager defaultManager] createDirectoryAtPath:directoryPath withIntermediateDirectories:YES attributes:nil error:nil];
            BOOL extracted = [archive extractFile:filename toPath:fullPath error:error];
            if (!extracted) {
                success = NO;
                break;
            }
        }
    }
    return success;
}

- (void)installModpackFromDetail:(NSDictionary *)detail atIndex:(NSInteger)index {
    // Get the download URL for the selected version.
    NSString *zipUrlString = detail[@"versionUrls"][index];
    if (!zipUrlString) {
        NSLog(@"No download URL available");
        return;
    }
    NSURL *zipUrl = [NSURL URLWithString:zipUrlString];
    
    // Define the destination path for installation.
    NSString *destPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"modpack_install"];
    [[NSFileManager defaultManager] createDirectoryAtPath:destPath withIntermediateDirectories:YES attributes:nil error:nil];
    
    // Synchronously download the ZIP (ideally perform this asynchronously).
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
    
    // Extract and parse manifest.json.
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
    
    // For each file in the manifest, download the mod file.
    NSArray *files = manifest[@"files"];
    for (NSDictionary *file in files) {
        NSNumber *projectID = file[@"projectID"];
        NSNumber *fileID = file[@"fileID"];
        BOOL required = [file[@"required"] boolValue];
        NSString *downloadUrl = [self getDownloadUrlForProject:[projectID longLongValue] file:[fileID longLongValue]];
        if (!downloadUrl && required) {
            NSLog(@"Failed to obtain download URL for project %@ file %@", projectID, fileID);
            return;
        }
        NSString *modsDir = [destPath stringByAppendingPathComponent:@"mods"];
        [[NSFileManager defaultManager] createDirectoryAtPath:modsDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *filePath = [modsDir stringByAppendingPathComponent:[downloadUrl lastPathComponent]];
        NSData *modData = [NSData dataWithContentsOfURL:[NSURL URLWithString:downloadUrl]];
        if (modData) {
            [modData writeToFile:filePath atomically:YES];
        }
    }
    
    // Extract overrides from the ZIP using our helper.
    NSString *overridesDir = manifest[@"overrides"] ?: @"overrides";
    if (![self extractDirectory:overridesDir fromArchive:archive toPath:destPath error:&error]) {
        NSLog(@"Failed to extract overrides: %@", error.localizedDescription);
        return;
    }
    
    // Delete the downloaded ZIP.
    [[NSFileManager defaultManager] removeItemAtPath:zipPath error:nil];
    
    // (Optionally) create or update a profile entry here.
    NSLog(@"Modpack installed successfully from CurseForge. (Profile creation to be implemented.)");
}

- (BOOL)verifyManifest:(NSDictionary *)manifest {
    if (![manifest[@"manifestType"] isEqualToString:@"minecraftModpack"]) return NO;
    if ([manifest[@"manifestVersion"] integerValue] != 1) return NO;
    if (!manifest[@"minecraft"]) return NO;
    if (!manifest[@"minecraft"][@"version"]) return NO;
    if (!manifest[@"minecraft"][@"modLoaders"] || [manifest[@"minecraft"][@"modLoaders"] count] < 1) return NO;
    return YES;
}

- (NSString *)getDownloadUrlForProject:(long long)projectID file:(long long)fileID {
    // First, try the official API endpoint.
    NSString *endpoint = [NSString stringWithFormat:@"mods/%lld/files/%lld/download-url", projectID, fileID];
    NSDictionary *response = [self getEndpoint:endpoint params:nil];
    id data = response[@"data"];
    if (data && ![data isKindOfClass:[NSNull class]]) {
        return (NSString *)data;
    }
    // Otherwise, fallback to retrieving file information.
    endpoint = [NSString stringWithFormat:@"mods/%lld/files/%lld", projectID, fileID];
    response = [self getEndpoint:endpoint params:nil];
    NSDictionary *modData = response[@"data"];
    if (modData) {
        NSInteger idValue = [modData[@"id"] integerValue];
        NSString *fileName = modData[@"fileName"];
        return [NSString stringWithFormat:@"https://edge.forgecdn.net/files/%ld/%ld/%@", (long)(idValue/1000), (long)(idValue % 1000), fileName];
    }
    return nil;
}

@end
