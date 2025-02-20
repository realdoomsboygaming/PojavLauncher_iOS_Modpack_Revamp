#import "CurseForgeAPI.h"
#import "UZKArchive.h"
#import "ModpackUtils.h"
#import "PLProfiles.h"

static const NSInteger kCurseForgeGameIDMinecraft = 432;
static const NSInteger kCurseForgeClassIDModpack  = 4471;
static const NSInteger kCurseForgeClassIDMod      = 6;

@implementation CurseForgeAPI

#pragma mark - Init

- (instancetype)initWithAPIKey:(NSString *)apiKey {
    self = [super init];
    if (self) {
        _apiKey = [apiKey copy];
        _previousOffset = 0;
        _reachedLastPage = NO;
        _lastSearchTerm = nil;
    }
    return self;
}

#pragma mark - loadAPIKey (optional)

- (NSString *)loadAPIKey {
    // Example usage if you want to load from environment:
    NSDictionary *environment = NSProcessInfo.processInfo.environment;
    NSString *envKey = environment[@"CURSEFORGE_API_KEY"];
    if (envKey.length == 0) {
        NSLog(@"[CurseForgeAPI] ⚠️ No environment CF API key found.");
        return nil;
    }
    return envKey;
}

#pragma mark - getEndpoint:params:

- (id)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params {
    // We'll build the URL with https://api.curseforge.com/v1/... plus query items
    NSString *baseURLString = [@"https://api.curseforge.com/v1/" stringByAppendingString:endpoint];
    NSURLComponents *components = [NSURLComponents componentsWithString:baseURLString];

    if ([params isKindOfClass:[NSDictionary class]]) {
        NSMutableArray<NSURLQueryItem *> *queryItems = [NSMutableArray array];
        for (NSString *key in params) {
            NSString *valString = [NSString stringWithFormat:@"%@", params[key]];
            [queryItems addObject:[NSURLQueryItem queryItemWithName:key value:valString]];
        }
        components.queryItems = queryItems;
    }

    __block id result = nil;
    __block NSError *taskError = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL];
    [request setValue:self.apiKey forHTTPHeaderField:@"x-api-key"];
    [request setValue:@"Mozilla/5.0" forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:request
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error)
    {
        if (error) {
            taskError = error;
        } else {
            NSError *jsonError = nil;
            id parsed = [NSJSONSerialization JSONObjectWithData:data
                                                        options:0
                                                          error:&jsonError];
            if (jsonError) {
                taskError = jsonError;
            } else {
                result = parsed;
            }
        }
        dispatch_semaphore_signal(sem);
    }];

    [task resume];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

    if (taskError) {
        self.lastError = taskError;
        return nil;
    }

    return result;
}

#pragma mark - Searching

- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, id> *)searchFilters
                      previousPageResult:(NSMutableArray *)previousResults
{
    // Basic parameters for searching MC modpacks or mods
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    params[@"gameId"] = @(kCurseForgeGameIDMinecraft);

    BOOL isModpack = [searchFilters[@"isModpack"] boolValue];
    params[@"classId"] = isModpack ? @(kCurseForgeClassIDModpack) : @(kCurseForgeClassIDMod);

    // Safely get the search name
    NSString *searchName = ([searchFilters[@"name"] isKindOfClass:[NSString class]]
                            ? searchFilters[@"name"]
                            : @"");
    params[@"searchFilter"] = searchName;

    // Sort by popularity or something else
    params[@"sortField"] = @(1);    // 1 = popularity
    params[@"sortOrder"] = @"desc"; // descending

    int limit = 50;
    params[@"pageSize"] = @(limit);

    // If we have a brand-new search, reset offset
    NSString *lastSearchName = self.lastSearchTerm ?: @"";
    if (!previousResults || ![searchName isEqualToString:lastSearchName]) {
        self.previousOffset = 0;
        self.reachedLastPage = NO;
    }
    params[@"index"] = @(self.previousOffset);

    // If a specific Minecraft version was requested
    if ([searchFilters[@"mcVersion"] isKindOfClass:[NSString class]] &&
        [searchFilters[@"mcVersion"] length] > 0)
    {
        params[@"gameVersion"] = searchFilters[@"mcVersion"];
    }

    NSDictionary *response = [self getEndpoint:@"mods/search" params:params];
    if (!response || ![response[@"data"] isKindOfClass:[NSArray class]]) {
        // If we hit an error, self.lastError is set
        return nil;
    }

    NSArray *dataArray = response[@"data"];
    NSMutableArray *results = previousResults ?: [NSMutableArray array];

    self.previousOffset += dataArray.count;
    self.reachedLastPage = (dataArray.count < limit);

    for (NSDictionary *modData in dataArray) {
        NSString *title = ([modData[@"name"] isKindOfClass:[NSString class]]
                           ? modData[@"name"]
                           : @"Unknown Title");
        NSString *summary = ([modData[@"summary"] isKindOfClass:[NSString class]]
                             ? modData[@"summary"]
                             : @"");

        // numeric ID
        id modIdValue = modData[@"id"];
        NSString *modId = ([modIdValue respondsToSelector:@selector(stringValue)]
                           ? [modIdValue stringValue]
                           : @"");

        // some have a "logo" dictionary with a "thumbnailUrl"
        NSDictionary *logoDict = ([modData[@"logo"] isKindOfClass:[NSDictionary class]]
                                  ? modData[@"logo"]
                                  : nil);
        NSString *imageUrl = (logoDict && [logoDict[@"thumbnailUrl"] isKindOfClass:[NSString class]]
                              ? logoDict[@"thumbnailUrl"]
                              : @"");

        // Build a dictionary consistent with your front-end
        NSMutableDictionary *item = [@{
            @"apiSource": @(0),            // 0 => CurseForge
            @"isModpack": @(isModpack),
            @"id": modId,
            @"title": title,
            @"description": summary,
            @"imageUrl": imageUrl
        } mutableCopy];

        // Pre-load version data so user can see "versionNames" right away
        [self loadDetailsOfMod:item];
        [results addObject:item];
    }

    // remember search term so we can handle pagination
    self.lastSearchTerm = searchName;
    return results;
}

#pragma mark - Loading Extra Details

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    // For CF, we often call GET /mods/:modId to get 'latestFiles' info
    NSString *modId = item[@"id"];
    if (!modId.length) {
        return;
    }
    NSString *endpoint = [NSString stringWithFormat:@"mods/%@", modId];

    NSDictionary *response = [self getEndpoint:endpoint params:nil];
    if (!response || ![response[@"data"] isKindOfClass:[NSDictionary class]]) {
        return;
    }

    NSDictionary *data = response[@"data"];
    NSArray *files = data[@"latestFiles"];
    if (![files isKindOfClass:[NSArray class]]) {
        return;
    }

    NSMutableArray *versionNames   = [NSMutableArray array];
    NSMutableArray *mcVersionNames = [NSMutableArray array];
    NSMutableArray *versionUrls    = [NSMutableArray array];

    for (NSDictionary *file in files) {
        // name
        NSString *displayName = ([file[@"displayName"] isKindOfClass:[NSString class]]
                                 ? file[@"displayName"]
                                 : @"Unnamed File");
        [versionNames addObject:displayName];

        // first MC version if any
        NSArray *gameVersions = ([file[@"gameVersions"] isKindOfClass:[NSArray class]]
                                 ? file[@"gameVersions"]
                                 : @[]);
        NSString *mcVersion = (gameVersions.count > 0 ? gameVersions.firstObject : @"");
        [mcVersionNames addObject:mcVersion];

        // direct download URL or build from file ID
        NSString *downloadUrl = @"";
        if ([file[@"downloadUrl"] isKindOfClass:[NSString class]]) {
            downloadUrl = file[@"downloadUrl"];
        } else {
            // if fileId is known, we can build the fallback:
            id fileIdValue = file[@"id"];
            NSString *fileId = ([fileIdValue respondsToSelector:@selector(stringValue)]
                                ? [fileIdValue stringValue]
                                : @"");
            NSString *fileName = ([file[@"fileName"] isKindOfClass:[NSString class]]
                                  ? file[@"fileName"]
                                  : @"unknown.jar");
            if (fileId.length >= 4) {
                // typical pattern: https://edge.forgecdn.net/files/1234/56/filename.jar
                NSString *prefix4 = [fileId substringToIndex:4];
                NSString *remainder = [fileId substringFromIndex:4];
                downloadUrl = [NSString stringWithFormat:
                    @"https://edge.forgecdn.net/files/%@/%@/%@", prefix4, remainder, fileName];
            }
        }
        [versionUrls addObject:downloadUrl ?: @""];
    }

    // store these so table can present them
    item[@"versionNames"] = versionNames;
    item[@"mcVersionNames"] = mcVersionNames;
    item[@"versionUrls"] = versionUrls;
}

#pragma mark - Install Modpack Inline

- (void)installModpackFromDetail:(NSDictionary *)detail atIndex:(NSInteger)index {
    // This downloads the ZIP from versionUrls[index], extracts, reads manifest.json
    // and sets up a PLProfiles entry, similar to how your Modrinth code does for mrpack.

    // 1) Validate
    if (![detail[@"versionUrls"] isKindOfClass:[NSArray class]]) {
        NSLog(@"[CurseForgeAPI] No versionUrls array in detail!");
        return;
    }
    NSArray *urls = detail[@"versionUrls"];
    if (index < 0 || index >= urls.count) {
        NSLog(@"[CurseForgeAPI] Invalid index %ld for versionUrls!", (long)index);
        return;
    }

    NSString *zipUrlString = urls[index];
    if (zipUrlString.length == 0) {
        NSLog(@"[CurseForgeAPI] Empty URL at index %ld!", (long)index);
        return;
    }
    NSURL *zipUrl = [NSURL URLWithString:zipUrlString];
    if (!zipUrl) {
        NSLog(@"[CurseForgeAPI] Could not build NSURL from: %@", zipUrlString);
        return;
    }

    // 2) Create a temp directory to store the downloaded .zip
    NSString *tempDir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"curseforge_install"];
    [[NSFileManager defaultManager] createDirectoryAtPath:tempDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    NSString *zipPath = [tempDir stringByAppendingPathComponent:@"modpack.zip"];

    // 3) Download synchronously using a semaphore
    __block NSError *downloadError = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    NSURLSessionDownloadTask *task = [[NSURLSession sharedSession]
       downloadTaskWithURL:zipUrl
         completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error)
    {
        if (error) {
            downloadError = error;
        } else {
            NSError *moveError = nil;
            [[NSFileManager defaultManager] moveItemAtURL:location
                                                    toURL:[NSURL fileURLWithPath:zipPath]
                                                    error:&moveError];
            if (moveError) {
                downloadError = moveError;
            }
        }
        dispatch_semaphore_signal(sem);
    }];
    [task resume];

    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    if (downloadError) {
        NSLog(@"[CurseForgeAPI] Download error: %@", downloadError.localizedDescription);
        return;
    }

    // 4) Extract the zip
    NSError *archiveError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:zipPath error:&archiveError];
    if (archiveError) {
        NSLog(@"[CurseForgeAPI] Failed to open modpack zip: %@", archiveError.localizedDescription);
        return;
    }
    NSError *extractError = nil;
    [archive extractFilesTo:tempDir overwrite:YES error:&extractError];
    if (extractError) {
        NSLog(@"[CurseForgeAPI] Failed to extract modpack: %@", extractError.localizedDescription);
        return;
    }

    // 5) Look for manifest.json
    NSString *manifestPath = [tempDir stringByAppendingPathComponent:@"manifest.json"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:manifestPath]) {
        NSLog(@"[CurseForgeAPI] No manifest.json found in the CF modpack!");
        return;
    }

    NSData *manifestData = [NSData dataWithContentsOfFile:manifestPath];
    if (!manifestData) {
        NSLog(@"[CurseForgeAPI] Could not load manifest.json data!");
        return;
    }

    NSError *jsonError = nil;
    NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:&jsonError];
    if (!manifest || jsonError) {
        NSLog(@"[CurseForgeAPI] Could not parse manifest.json: %@", jsonError.localizedDescription);
        return;
    }

    // 6) Extract overrides (if any)
    NSError *overridesError = nil;
    [ModpackUtils archive:archive extractDirectory:@"overrides" toPath:tempDir error:&overridesError];
    [ModpackUtils archive:archive extractDirectory:@"Overrides" toPath:tempDir error:&overridesError];
    if (overridesError) {
        NSLog(@"[CurseForgeAPI] Could not extract overrides: %@", overridesError.localizedDescription);
        // Not necessarily fatal, but you can handle it as needed
    }

    // remove the original .zip
    [[NSFileManager defaultManager] removeItemAtPath:zipPath error:nil];

    // 7) Move everything to a final directory named after the pack
    NSString *packName = ([manifest[@"name"] isKindOfClass:[NSString class]]
                          ? manifest[@"name"]
                          : @"CF_Pack");
    NSString *finalInstallPath = [NSTemporaryDirectory() stringByAppendingPathComponent:packName];
    NSError *moveAllError = nil;
    [[NSFileManager defaultManager] moveItemAtPath:tempDir
                                            toPath:finalInstallPath
                                             error:&moveAllError];
    if (moveAllError) {
        NSLog(@"[CurseForgeAPI] Could not rename temp folder: %@", moveAllError.localizedDescription);
        return;
    }

    // 8) Read the 'minecraft' => 'modLoaders' to figure out e.g. "forge-1.19.2-..."
    NSDictionary *mcSection = manifest[@"minecraft"];
    NSString *profileVersionID = @"";
    if ([mcSection isKindOfClass:[NSDictionary class]]) {
        NSArray *loaders = mcSection[@"modLoaders"];
        if ([loaders isKindOfClass:[NSArray class]] && loaders.count > 0) {
            NSDictionary *firstLoader = loaders.firstObject;
            if ([firstLoader[@"id"] isKindOfClass:[NSString class]]) {
                profileVersionID = firstLoader[@"id"]; // e.g. "forge-xx.xx.xx"
            }
        }
    }

    // 9) Update PLProfiles
    NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
    NSData *iconData = [NSData dataWithContentsOfFile:tmpIconPath];
    NSString *iconBase64 = iconData ? [iconData base64EncodedStringWithOptions:0] : @"";

    PLProfiles *profiles = [PLProfiles current];
    profiles.profiles[packName] = [@{
        @"gameDir": [NSString stringWithFormat:@"./custom_gamedir/%@", finalInstallPath.lastPathComponent],
        @"name": packName,
        @"lastVersionId": profileVersionID ?: @"",
        @"icon": [NSString stringWithFormat:@"data:image/png;base64,%@", iconBase64]
    } mutableCopy];

    profiles.selectedProfileName = packName;
    NSLog(@"[CurseForgeAPI] Successfully installed CF modpack named: %@", packName);
}

@end
