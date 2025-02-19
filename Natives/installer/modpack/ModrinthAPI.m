#import "ModrinthAPI.h"
#import "MinecraftResourceDownloadTask.h"
#import "PLProfiles.h"
#import "ModpackUtils.h"
#import "UZKArchive.h"

@implementation ModrinthAPI

#pragma mark - Searching Mods

- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, NSString *> *)searchFilters
                       previousPageResult:(NSMutableArray *)modrinthSearchResult
{
    int limit = 50;
    
    // Build the facets
    NSMutableString *facetString = [NSMutableString new];
    [facetString appendString:@"[[\"project_type:%@\"]]"];
    [facetString replaceOccurrencesOfString:@"%@"
                                 withString:(searchFilters[@"isModpack"].boolValue ? @"modpack" : @"mod")
                                    options:0
                                      range:NSMakeRange(0, facetString.length)];
    
    if (searchFilters[@"mcVersion"].length > 0) {
        [facetString appendFormat:@",[[\"versions:%@\"]]", searchFilters[@"mcVersion"]];
    }
    
    NSDictionary *params = @{
        @"facets": facetString,
        @"query": [searchFilters[@"name"] stringByReplacingOccurrencesOfString:@" " withString:@"+"],
        @"limit": @(limit),
        @"index": @"relevance",
        @"offset": @(modrinthSearchResult.count ?: 0) // Just in case it's nil
    };
    
    NSDictionary *response = [self getEndpoint:@"search" params:params];
    if (!response) {
        return nil; // self.lastError is presumably set by getEndpoint:
    }
    
    NSMutableArray *result = modrinthSearchResult ?: [NSMutableArray new];
    for (NSDictionary *hit in response[@"hits"]) {
        BOOL isModpack = [hit[@"project_type"] isEqualToString:@"modpack"];
        [result addObject:@{
            @"apiSource": @(1),
            @"isModpack": @(isModpack),
            @"id": hit[@"project_id"] ?: @"",
            @"title": hit[@"title"] ?: @"",
            @"description": hit[@"description"] ?: @"",
            @"imageUrl": hit[@"icon_url"] ?: @""
        }.mutableCopy];
    }
    
    // Keep track if we've reached the last page
    self.reachedLastPage = result.count >= [response[@"total_hits"] unsignedLongValue];
    return result;
}

#pragma mark - Loading Details

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    NSArray *response = [self getEndpoint:[NSString stringWithFormat:@"project/%@/version", item[@"id"]] params:nil];
    if (!response || ![response isKindOfClass:[NSArray class]]) {
        return;
    }
    
    NSArray *names = [response valueForKey:@"name"];
    NSMutableArray *mcNames = [NSMutableArray new];
    NSMutableArray *urls = [NSMutableArray new];
    NSMutableArray *hashes = [NSMutableArray new];
    NSMutableArray *sizes = [NSMutableArray new];
    
    // Each version in response has "files": ...
    [response enumerateObjectsUsingBlock:^(NSDictionary *version, NSUInteger i, BOOL *stop) {
        NSDictionary *file = [version[@"files"] firstObject];
        if (![file isKindOfClass:[NSDictionary class]]) {
            return;
        }
        NSString *gameVersion = [version[@"game_versions"] firstObject] ?: @"";
        [mcNames addObject:gameVersion];
        
        NSNumber *fileSize = file[@"size"] ?: @0;
        [sizes addObject:fileSize];
        
        NSString *urlString = file[@"url"] ?: @"";
        [urls addObject:urlString];
        
        NSDictionary *hashesMap = file[@"hashes"];
        NSString *sha1Hash = hashesMap[@"sha1"];
        [hashes addObject:sha1Hash ?: [NSNull null]];
    }];
    
    item[@"versionNames"] = names;
    item[@"mcVersionNames"] = mcNames;
    item[@"versionSizes"] = sizes;
    item[@"versionUrls"] = urls;
    item[@"versionHashes"] = hashes;
    item[@"versionDetailsLoaded"] = @(YES);
}

#pragma mark - Installing a Modpack

- (void)installModpackFromDetail:(NSDictionary *)detail atIndex:(NSInteger)index {
    if (![detail[@"versionUrls"] isKindOfClass:[NSArray class]]) {
        return;
    }
    NSString *packageUrl = detail[@"versionUrls"][index];
    if (packageUrl.length == 0) {
        return;
    }
    
    NSString *destPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"modrinth_install"];
    [[NSFileManager defaultManager] createDirectoryAtPath:destPath
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    
    NSURLSessionDownloadTask *task = [[NSURLSession sharedSession]
       downloadTaskWithURL:[NSURL URLWithString:packageUrl]
         completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error)
    {
        if (error) {
            NSLog(@"[ModrinthAPI] Download error: %@", error.localizedDescription);
            return;
        }
        
        NSString *packagePath = [destPath stringByAppendingPathComponent:@"modpack.mrpack"];
        [[NSFileManager defaultManager] moveItemAtURL:location
                                                toURL:[NSURL fileURLWithPath:packagePath]
                                                error:nil];
        
        MinecraftResourceDownloadTask *downloader = [MinecraftResourceDownloadTask new];
        [self downloader:downloader submitDownloadTasksFromPackage:packagePath toPath:destPath];
    }];
    [task resume];
}

#pragma mark - Submit Download Tasks

- (void)downloader:(MinecraftResourceDownloadTask *)downloader
submitDownloadTasksFromPackage:(NSString *)packagePath
            toPath:(NSString *)destPath
{
    NSError *error;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:packagePath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to open modpack package: %@", error.localizedDescription]];
        return;
    }
    
    NSData *indexData = [archive extractDataFromFile:@"modrinth.index.json" error:&error];
    if (!indexData || error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to parse modrinth.index.json: %@", error.localizedDescription]];
        return;
    }
    
    NSDictionary *indexDict = [NSJSONSerialization JSONObjectWithData:indexData options:0 error:&error];
    if (!indexDict || error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to parse modrinth.index.json (JSON error): %@", error.localizedDescription]];
        return;
    }
    
    // Start downloading each file
    NSArray *files = indexDict[@"files"];
    if (![files isKindOfClass:[NSArray class]]) {
        [downloader finishDownloadWithErrorString:@"The modrinth.index.json is missing 'files' array."];
        return;
    }
    downloader.progress.totalUnitCount = files.count;
    
    for (NSDictionary *indexFile in files) {
        NSString *url = [indexFile[@"downloads"] firstObject];
        NSString *sha = indexFile[@"hashes"][@"sha1"];
        NSString *path = [destPath stringByAppendingPathComponent:indexFile[@"path"]];
        NSUInteger size = [indexFile[@"fileSize"] unsignedLongLongValue];
        
        NSURLSessionDownloadTask *task = [downloader createDownloadTask:url
                                                                  size:size
                                                                   sha:sha
                                                               altName:nil
                                                                toPath:path];
        if (task) {
            [downloader.fileList addObject:indexFile[@"path"]];
            [task resume];
        }
    }
    
    // Extract overrides
    [ModpackUtils archive:archive extractDirectory:@"overrides" toPath:destPath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract overrides: %@", error.localizedDescription]];
        return;
    }
    
    [ModpackUtils archive:archive extractDirectory:@"client-overrides" toPath:destPath error:&error];
    if (error) {
        [downloader finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to extract client-overrides: %@", error.localizedDescription]];
        return;
    }
    
    // Remove the .mrpack
    [[NSFileManager defaultManager] removeItemAtPath:packagePath error:nil];
    
    // Handle dependencies
    NSDictionary<NSString *, NSString *> *depInfo = [ModpackUtils infoForDependencies:indexDict[@"dependencies"]];
    if (depInfo[@"json"]) {
        NSString *jsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json",
                              getenv("POJAV_GAME_DIR"), depInfo[@"id"]];
        NSURLSessionDownloadTask *depTask = [downloader createDownloadTask:depInfo[@"json"]
                                                                     size:0
                                                                      sha:nil
                                                                  altName:nil
                                                                   toPath:jsonPath];
        [depTask resume];
    }
    
    // Attempt to set up the profile in PLProfiles
    NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
    NSData *iconData = [NSData dataWithContentsOfFile:tmpIconPath];
    NSString *base64Icon = iconData ? [iconData base64EncodedStringWithOptions:0] : @"";
    
    if (indexDict[@"name"]) {
        PLProfiles.current.profiles[indexDict[@"name"]] = [@{
            @"gameDir": [NSString stringWithFormat:@"./custom_gamedir/%@", destPath.lastPathComponent],
            @"name": indexDict[@"name"],
            @"lastVersionId": depInfo[@"id"] ?: @"",
            @"icon": [NSString stringWithFormat:@"data:image/png;base64,%@", base64Icon]
        } mutableCopy];
        PLProfiles.current.selectedProfileName = indexDict[@"name"];
    }
}

@end
