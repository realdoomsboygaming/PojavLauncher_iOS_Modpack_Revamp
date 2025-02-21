#import <CommonCrypto/CommonDigest.h>
#import "authenticator/BaseAuthenticator.h"
#import "installer/modpack/ModpackAPI.h"
#import "AFNetworking.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "MinecraftResourceDownloadTask.h"
#import "MinecraftResourceUtils.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

@interface MinecraftResourceDownloadTask ()
@property AFURLSessionManager* manager;
@end

@implementation MinecraftResourceDownloadTask

- (instancetype)init {
    self = [super init];
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
    configuration.timeoutIntervalForRequest = 86400;
    self.manager = [[AFURLSessionManager alloc] initWithSessionConfiguration:configuration];
    self.fileList = [NSMutableArray new];
    self.progressList = [NSMutableArray new];
    return self;
}

- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path {
    return [self createDownloadTask:url size:size sha:sha altName:altName toPath:path success:nil];
}

- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path success:(void (^)(void))success {
    BOOL fileExists = [[NSFileManager defaultManager] fileExistsAtPath:path];
    if (fileExists && [self checkSHA:sha forFile:path altName:altName]) {
        if (success) success();
        return nil;
    } else if (![self checkAccessWithDialog:YES]) {
        return nil;
    }
    NSString *name = altName ?: path.lastPathComponent;
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:url]];
    __block NSProgress *progress;
    __block NSURLSessionDownloadTask *task = [self.manager downloadTaskWithRequest:request progress:nil destination:^NSURL * (NSURL *targetPath, NSURLResponse *response) {
        NSLog(@"[MCDL] Downloading %@", name);
        progress = [self.manager downloadProgressForTask:task];
        if (!size && task) {
            [self addDownloadTaskToProgress:task size:response.expectedContentLength];
            [self.fileList addObject:name];
        }
        [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
        return [NSURL fileURLWithPath:path];
    } completionHandler:^(NSURLResponse *response, NSURL *filePath, NSError *error) {
        if (self.progress.cancelled) {
        } else if (error != nil) {
            [self finishDownloadWithError:error file:name];
        } else if (![self checkSHA:sha forFile:path altName:altName]) {
            [self finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to verify file %@: SHA1 mismatch", path.lastPathComponent]];
        } else {
            progress.totalUnitCount = progress.completedUnitCount;
            if (success) success();
        }
    }];
    if (size && task) {
        [self addDownloadTaskToProgress:task size:size];
        [self.fileList addObject:name];
    }
    return task;
}

- (void)addDownloadTaskToProgress:(NSURLSessionDownloadTask *)task size:(NSInteger)size {
    NSProgress *progress = [self.manager downloadProgressForTask:task];
    NSUInteger fileSize = size > 0 ? size : 1;
    progress.kind = NSProgressKindFile;
    if (size > 0) {
        progress.totalUnitCount = fileSize;
    }
    [self.progressList addObject:progress];
    [self.progress addChild:progress withPendingUnitCount:fileSize];
    self.progress.totalUnitCount += fileSize;
    self.textProgress.totalUnitCount = self.progress.totalUnitCount;
}

- (void)downloadVersionMetadata:(NSDictionary *)version success:(void (^)(void))success {
    NSString *versionStr = version[@"id"];
    if ([versionStr isEqualToString:@"latest-release"]) {
        versionStr = getPrefObject(@"internal.latest_version.release");
    } else if ([versionStr isEqualToString:@"latest-snapshot"]) {
        versionStr = getPrefObject(@"internal.latest_version.snapshot");
    }
    NSString *path = [NSString stringWithFormat:@"%s/versions/%@/%@.json", getenv("POJAV_GAME_DIR"), versionStr, versionStr];
    version = (id)[MinecraftResourceUtils findVersion:versionStr inList:remoteVersionList];
    void (^completionBlock)(void) = ^{
        self.metadata = parseJSONFromFile(path);
        if (self.metadata[@"NSErrorObject"]) {
            [self finishDownloadWithErrorString:[self.metadata[@"NSErrorObject"] localizedDescription]];
            return;
        }
        if (self.metadata[@"inheritsFrom"]) {
            NSMutableDictionary *inheritsFromDict = parseJSONFromFile([NSString stringWithFormat:@"%s/versions/%@/%@.json", getenv("POJAV_GAME_DIR"), self.metadata[@"inheritsFrom"], self.metadata[@"inheritsFrom"]]);
            if (inheritsFromDict) {
                [MinecraftResourceUtils processVersion:self.metadata inheritsFrom:inheritsFromDict];
                self.metadata = inheritsFromDict;
            }
        }
        [MinecraftResourceUtils tweakVersionJson:self.metadata];
        success();
    };
    if (!version) {
        NSMutableDictionary *json = parseJSONFromFile(path);
        if (json[@"NSErrorObject"]) {
            [self finishDownloadWithErrorString:[json[@"NSErrorObject"] localizedDescription]];
            return;
        } else if (json[@"inheritsFrom"]) {
            version = (id)[MinecraftResourceUtils findVersion:json[@"inheritsFrom"] inList:remoteVersionList];
            path = [NSString stringWithFormat:@"%s/versions/%@/%@.json", getenv("POJAV_GAME_DIR"), json[@"inheritsFrom"], json[@"inheritsFrom"]];
        } else {
            completionBlock();
            return;
        }
    }
    versionStr = version[@"id"];
    NSString *url = version[@"url"];
    NSString *sha = url.stringByDeletingLastPathComponent.lastPathComponent;
    NSUInteger size = [version[@"size"] unsignedLongLongValue];
    NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:nil toPath:path success:completionBlock];
    [task resume];
}

- (void)downloadAssetMetadataWithSuccess:(void (^)(void))success {
    NSDictionary *assetIndex = self.metadata[@"assetIndex"];
    if (!assetIndex) {
        success();
        return;
    }
    NSString *name = [NSString stringWithFormat:@"assets/indexes/%@.json", assetIndex[@"id"]];
    NSString *path = [@(getenv("POJAV_GAME_DIR")) stringByAppendingPathComponent:name];
    NSString *url = assetIndex[@"url"];
    NSString *sha = url.stringByDeletingLastPathComponent.lastPathComponent;
    NSUInteger size = [assetIndex[@"size"] unsignedLongLongValue];
    NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:name toPath:path success:^{
        self.metadata[@"assetIndexObj"] = parseJSONFromFile(path);
        success();
    }];
    [task resume];
}

- (NSArray *)downloadClientLibraries {
    NSMutableArray *tasks = [NSMutableArray new];
    for (NSDictionary *library in self.metadata[@"libraries"]) {
        NSString *name = library[@"name"];
        NSMutableDictionary *artifact = library[@"downloads"][@"artifact"];
        if (!artifact && [name containsString:@":"]) {
            artifact = [NSMutableDictionary new];
            NSString *prefix = library[@"url"] ? [library[@"url"] stringByReplacingOccurrencesOfString:@"http://" withString:@"https://"] : @"https://libraries.minecraft.net/";
            NSArray *libParts = [name componentsSeparatedByString:@":"];
            artifact[@"path"] = [NSString stringWithFormat:@"%@/%@/%@/%@-%@.jar", [libParts[0] stringByReplacingOccurrencesOfString:@"." withString:@"/"], libParts[1], libParts[2], libParts[1], libParts[2]];
            artifact[@"url"] = [NSString stringWithFormat:@"%@%@", prefix, artifact[@"path"]];
            artifact[@"sha1"] = library[@"checksums"][0];
        }
        NSString *path = [NSString stringWithFormat:@"%s/libraries/%@", getenv("POJAV_GAME_DIR"), artifact[@"path"]];
        NSString *sha = artifact[@"sha1"];
        NSUInteger size = [artifact[@"size"] unsignedLongLongValue];
        NSString *url = artifact[@"url"];
        if ([library[@"skip"] boolValue]) {
            continue;
        }
        NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:name toPath:path success:nil];
        if (task) {
            [tasks addObject:task];
        } else if (self.progress.cancelled) {
            return nil;
        }
    }
    return tasks;
}

- (NSArray *)downloadClientAssets {
    NSMutableArray *tasks = [NSMutableArray new];
    NSDictionary *assets = self.metadata[@"assetIndexObj"];
    if (!assets) {
        return @[];
    }
    for (NSString *name in assets[@"objects"]) {
        NSDictionary *object = assets[@"objects"][name];
        NSString *hash = object[@"hash"];
        NSString *pathname = [NSString stringWithFormat:@"%@/%@", [hash substringToIndex:2], hash];
        NSUInteger size = [object[@"size"] unsignedLongLongValue];
        NSString *path;
        if ([assets[@"map_to_resources"] boolValue]) {
            path = [NSString stringWithFormat:@"%s/resources/%@", getenv("POJAV_GAME_DIR"), name];
        } else {
            path = [NSString stringWithFormat:@"%s/assets/objects/%@", getenv("POJAV_GAME_DIR"), pathname];
        }
        if ([name hasSuffix:@"/minecraft.icns"]) {
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            continue;
        }
        NSString *url = [NSString stringWithFormat:@"https://resources.download.minecraft.net/%@", pathname];
        NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:hash altName:name toPath:path success:nil];
        if (task) {
            [tasks addObject:task];
        } else if (self.progress.cancelled) {
            return nil;
        }
    }
    return tasks;
}

- (void)downloadVersion:(NSDictionary *)version {
    [self prepareForDownload];
    [self downloadVersionMetadata:version success:^{
        [self downloadAssetMetadataWithSuccess:^{
            NSArray *libTasks = [self downloadClientLibraries];
            NSArray *assetTasks = [self downloadClientAssets];
            self.progress.totalUnitCount--;
            self.textProgress.totalUnitCount--;
            if (self.progress.totalUnitCount == 0) {
                self.progress.totalUnitCount = 1;
                self.progress.completedUnitCount = 1;
                self.textProgress.totalUnitCount = 1;
                self.textProgress.completedUnitCount = 1;
                return;
            }
            [libTasks makeObjectsPerformSelector:@selector(resume)];
            [assetTasks makeObjectsPerformSelector:@selector(resume)];
            [self.metadata removeObjectForKey:@"assetIndexObj"];
        }];
    }];
}

- (void)downloadModpackFromAPI:(ModpackAPI *)api detail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion {
    [self prepareForDownload];
    NSString *url = modDetail[@"versionUrls"][selectedVersion];
    NSUInteger size = [modDetail[@"versionSizes"][selectedVersion] unsignedLongLongValue];
    NSString *sha = modDetail[@"versionHashes"][selectedVersion];
    NSString *name = [[modDetail[@"title"] lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    name = [name stringByReplacingOccurrencesOfString:@" " withString:@"_"];
    NSString *packagePath = [NSTemporaryDirectory() stringByAppendingFormat:@"/%@.zip", name];
    NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:nil toPath:packagePath success:^{
        NSString *path = [NSString stringWithFormat:@"%s/custom_gamedir/%@", getenv("POJAV_GAME_DIR"), name];
        [api downloader:self submitDownloadTasksFromPackage:packagePath toPath:path];
    }];
    [task resume];
}

- (void)prepareForDownload {
    self.textProgress = [NSProgress new];
    self.textProgress.kind = NSProgressKindFile;
    self.textProgress.fileOperationKind = NSProgressFileOperationKindDownloading;
    self.textProgress.totalUnitCount = -1;
    self.progress = [NSProgress new];
    self.progress.totalUnitCount = 1;
    [self.fileList removeAllObjects];
    [self.progressList removeAllObjects];
}

- (void)finishDownloadWithErrorString:(NSString *)error {
    [self.progress cancel];
    [self.manager invalidateSessionCancelingTasks:YES resetSession:YES];
    showDialog(localize(@"Error", nil), error);
    if (self.handleError) {
        self.handleError();
    }
}

- (void)finishDownloadWithError:(NSError *)error file:(NSString *)file {
    NSString *errorStr = [NSString stringWithFormat:localize(@"launcher.mcl.error_download", nil), file, error.localizedDescription];
    NSLog(@"[MCDL] Error: %@ %@", errorStr, [NSThread callStackSymbols]);
    [self finishDownloadWithErrorString:errorStr];
}

- (BOOL)checkAccessWithDialog:(BOOL)show {
    BOOL accessible = [BaseAuthenticator.current.authData[@"username"] hasPrefix:@"Demo."] || BaseAuthenticator.current.authData[@"xboxGamertag"] != nil;
    if (!accessible) {
        [self.progress cancel];
        if (show) {
            [self finishDownloadWithErrorString:@"Minecraft can't be legally installed when logged in with a local account. Please switch to an online account to continue."];
        }
    }
    return accessible;
}

- (BOOL)checkSHAIgnorePref:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName logSuccess:(BOOL)logSuccess {
    if (sha.length == 0) {
        BOOL existence = [[NSFileManager defaultManager] fileExistsAtPath:path];
        if (existence) {
            NSLog(@"[MCDL] Warning: couldn't find SHA for %@, assuming valid", altName ? altName : path.lastPathComponent);
        }
        return existence;
    }
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        NSLog(@"[MCDL] SHA1 checker: file doesn't exist: %@", altName ? altName : path.lastPathComponent);
        return NO;
    }
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *localSHA = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [localSHA appendFormat:@"%02x", digest[i]];
    }
    BOOL check = [sha isEqualToString:localSHA];
    if (!check || (getPrefBool(@"general.debug_logging") && logSuccess)) {
        NSLog(@"[MCDL] SHA1 %@ for %@%@", (check ? @"passed" : @"failed"), (altName ? altName : path.lastPathComponent), (check ? @"" : [NSString stringWithFormat:@" (expected: %@, got: %@)", sha, localSHA]));
    }
    return check;
}

- (BOOL)checkSHA:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName {
    if (getPrefBool(@"general.check_sha")) {
        return [self checkSHAIgnorePref:sha forFile:path altName:altName logSuccess:(altName == nil)];
    } else {
        return [[NSFileManager defaultManager] fileExistsAtPath:path];
    }
}

@end
