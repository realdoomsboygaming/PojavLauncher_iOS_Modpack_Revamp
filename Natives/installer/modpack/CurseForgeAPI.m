#import "CurseForgeAPI.h"
#import "UZKArchive.h"

// Constants for CurseForge API
static const NSInteger kCurseForgeGameIDMinecraft = 432;
static const NSInteger kCurseForgeClassIDModpack = 4471;
static const NSInteger kCurseForgeClassIDMod = 6;

@implementation CurseForgeAPI

@dynamic lastError;
@dynamic reachedLastPage;

- (instancetype)init {
    self = [super initWithURL:@"https://api.curseforge.com/v1"];
    if (self) {
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

- (BOOL)extractDirectory:(NSString *)directory fromArchive:(UZKArchive *)archive toPath:(NSString *)destPath error:(NSError **)error {
    NSArray<NSString *> *filenames = [archive listFilenames:error];
    if (!filenames) {
        return NO;
    }

    BOOL success = YES;
    NSFileManager *fileManager = [NSFileManager defaultManager];

    for (NSString *filename in filenames) {
        if ([filename hasPrefix:directory]) {
            NSString *fullPath = [destPath stringByAppendingPathComponent:filename];
            NSString *parentDir = [fullPath stringByDeletingLastPathComponent];

            [fileManager createDirectoryAtPath:parentDir withIntermediateDirectories:YES attributes:nil error:nil];

            NSData *fileData = [archive extractDataFromFile:filename error:error];
            if (!fileData) {
                success = NO;
                break;
            }
            [fileData writeToFile:fullPath atomically:YES];
        }
    }
    return success;
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
