#include <CommonCrypto/CommonDigest.h>

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
@property (nonatomic, strong) AFURLSessionManager *manager;
@property (nonatomic, assign) NSUInteger activeDownloads; // Active downloads counter
@end

@implementation MinecraftResourceDownloadTask

- (instancetype)init {
    self = [super init];
    if (self) {
        // Use default configuration
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        configuration.timeoutIntervalForRequest = 86400;
        self.manager = [[AFURLSessionManager alloc] initWithSessionConfiguration:configuration];
        self.fileList = [NSMutableArray new];
        self.progressList = [NSMutableArray new];
        self.activeDownloads = 0;
    }
    return self;
}

// Our main createDownloadTask: method with a success callback
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url
                                           size:(NSUInteger)size
                                            sha:(NSString *)sha
                                        altName:(NSString *)altName
                                          toPath:(NSString *)path
                                        success:(void(^)(void))success
{
    BOOL fileExists = [NSFileManager.defaultManager fileExistsAtPath:path];
    if (fileExists && [self checkSHA:sha forFile:path altName:altName]) {
        if (success) success();
        return nil;
    } else if (![self checkAccessWithDialog:YES]) {
        return nil;
    }
    
    // Use altName if provided, otherwise use the file name from the path.
    NSString *name = altName ?: path.lastPathComponent;
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:url]];
    
    // Increase active downloads counter
    self.activeDownloads++;
    
    __block NSProgress *childProgress = nil;
    NSURLSessionDownloadTask *task = [self.manager downloadTaskWithRequest:request
        progress:nil
        destination:^NSURL * _Nonnull(NSURL * _Nonnull targetPath, NSURLResponse * _Nonnull response) {
            NSLog(@"[MCDL] Downloading %@", name);
            // Ensure the destination directory exists
            [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                                    withIntermediateDirectories:YES
                                                     attributes:nil error:nil];
            [NSFileManager.defaultManager removeItemAtPath:path error:nil];
            return [NSURL fileURLWithPath:path];
        }
        completionHandler:^(NSURLResponse * _Nonnull response, NSURL * _Nullable filePath, NSError * _Nullable error)
        {
            // Decrease active downloads counter when task finishes
            self.activeDownloads--;
            
            // If only one file remains active, trigger finalization.
            if (self.activeDownloads == 1) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSLog(@"[MCDL] Only one file remaining, proceeding to finalization.");
                    [self finalizeDownloads];
                });
            }
            
            if (self.progress.cancelled) {
                // If cancelled, ignore errors.
            } else if (error != nil) {
                [self finishDownloadWithError:error file:name];
            } else if (![self checkSHA:sha forFile:path altName:altName]) {
                [self finishDownloadWithErrorString:[NSString stringWithFormat:
                    @"Failed to verify file %@: SHA1 mismatch", path.lastPathComponent]];
            } else {
                // Mark childProgress as "finished" by forcibly setting completed to total:
                if (childProgress) {
                    [childProgress willChangeValueForKey:@"fractionCompleted"];
                    childProgress.completedUnitCount = childProgress.totalUnitCount;
                    [childProgress didChangeValueForKey:@"fractionCompleted"];
                }
                if (success) success();
            }
        }
    ];
    
    // If a valid task was created, add it to our overall progress and file list.
    if (task) {
        childProgress = [self.manager downloadProgressForTask:task];
        // Set the progress total to the actual file size (in bytes)
        childProgress.totalUnitCount = size;
        [self addChildProgress:childProgress];
        
        // Normalize the file name for duplicate checking.
        NSString *normalizedName = name;
        if ([normalizedName hasPrefix:@"mods/"]) {
            normalizedName = [normalizedName substringFromIndex:5];
        }
        BOOL duplicate = NO;
        @synchronized(self.fileList) {
            for (NSString *existing in self.fileList) {
                NSString *normalizedExisting = existing;
                if ([normalizedExisting hasPrefix:@"mods/"]) {
                    normalizedExisting = [normalizedExisting substringFromIndex:5];
                }
                if ([normalizedExisting isEqualToString:normalizedName]) {
                    duplicate = YES;
                    break;
                }
            }
            if (!duplicate) {
                [self.fileList addObject:name];
            }
        }
        
        // Keep the childProgress in progressList for the UI
        @synchronized(self.progressList) {
            [self.progressList addObject:childProgress];
        }
    }
    
    return task;
}

// Convenience method without the 'success' callback
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url
                                           size:(NSUInteger)size
                                            sha:(NSString *)sha
                                        altName:(NSString *)altName
                                          toPath:(NSString *)path
{
    return [self createDownloadTask:url size:size sha:sha altName:altName toPath:path success:nil];
}

// Updated addChildProgress method that uses the actual file size for progress.
- (void)addChildProgress:(NSProgress *)childProgress {
    childProgress.kind = NSProgressKindFile;
    [self.progress addChild:childProgress withPendingUnitCount:childProgress.totalUnitCount];
    self.progress.totalUnitCount += childProgress.totalUnitCount;
    self.textProgress.totalUnitCount = self.progress.totalUnitCount;
}

// Download version metadata
- (void)downloadVersionMetadata:(NSDictionary *)version success:(void(^)(void))success {
    NSString *versionStr = version[@"id"];
    if ([versionStr isEqualToString:@"latest-release"]) {
        versionStr = getPrefObject(@"internal.latest_version.release");
    } else if ([versionStr isEqualToString:@"latest-snapshot"]) {
        versionStr = getPrefObject(@"internal.latest_version.snapshot");
    }
    
    NSString *path = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json",
                      getenv("POJAV_GAME_DIR"), versionStr];
    version = (id)[MinecraftResourceUtils findVersion:versionStr inList:remoteVersionList];
    
    void(^completionBlock)(void) = ^ {
        self.metadata = parseJSONFromFile(path);
        if (self.metadata[@"NSErrorObject"]) {
            [self finishDownloadWithErrorString:[self.metadata[@"NSErrorObject"] localizedDescription]];
            return;
        }
        if (self.metadata[@"inheritsFrom"]) {
            NSMutableDictionary *inheritsFromDict = parseJSONFromFile([NSString stringWithFormat:
                @"%1$s/versions/%2$@/%2$@.json",
                getenv("POJAV_GAME_DIR"), self.metadata[@"inheritsFrom"]]);
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
            path = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json",
                    getenv("POJAV_GAME_DIR"), json[@"inheritsFrom"]];
        } else {
            completionBlock();
            return;
        }
    }
    
    versionStr = version[@"id"];
    NSString *url = version[@"url"];
    NSString *shaLocal = url.stringByDeletingLastPathComponent.lastPathComponent;
    NSUInteger size = [version[@"size"] unsignedLongLongValue];
    
    NSURLSessionDownloadTask *task = [self createDownloadTask:url
                                                        size:size
                                                         sha:shaLocal
                                                     altName:nil
                                                       toPath:path
                                                      success:completionBlock];
    [task resume];
}

// Download the asset index if needed
- (void)downloadAssetMetadataWithSuccess:(void(^)(void))success {
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

// Download version libraries
- (NSArray *)downloadClientLibraries {
    NSMutableArray *tasks = [NSMutableArray new];
    for (NSDictionary *library in self.metadata[@"libraries"]) {
        NSString *name = library[@"name"];
        NSMutableDictionary *artifact = library[@"downloads"][@"artifact"];
        if (artifact == nil && [name containsString:@":"]) {
            NSLog(@"[MCDL] Unknown artifact object for %@, generating", name);
            artifact = [[NSMutableDictionary alloc] init];
            NSString *prefix = library[@"url"] == nil
                ? @"https://libraries.minecraft.net/"
                : [library[@"url"] stringByReplacingOccurrencesOfString:@"http://" withString:@"https://"];
            NSArray *libParts = [name componentsSeparatedByString:@":"];
            artifact[@"path"] = [NSString stringWithFormat:
                @"%1$@/%2$@/%3$@/%2$@-%3$@.jar",
                [libParts[0] stringByReplacingOccurrencesOfString:@"." withString:@"/"],
                libParts[1],
                libParts[2]
            ];
            artifact[@"url"] = [NSString stringWithFormat:@"%@%@", prefix, artifact[@"path"]];
            artifact[@"sha1"] = library[@"checksums"][0];
        }
        
        NSString *path = [NSString stringWithFormat:@"%s/libraries/%@", getenv("POJAV_GAME_DIR"), artifact[@"path"]];
        NSString *sha = artifact[@"sha1"];
        NSUInteger size = [artifact[@"size"] unsignedLongLongValue];
        NSString *url = artifact[@"url"];
        if ([library[@"skip"] boolValue]) {
            NSLog(@"[MCDL] Skipped library %@", name);
            continue;
        }
        
        NSURLSessionDownloadTask *task =
            [self createDownloadTask:url size:size sha:sha altName:name toPath:path success:nil];
        if (task) {
            [tasks addObject:task];
        } else if (self.progress.cancelled) {
            return nil;
        }
    }
    return tasks;
}

// Download assets
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
            [NSFileManager.defaultManager removeItemAtPath:path error:nil];
            continue;
        }
        
        NSString *url = [NSString stringWithFormat:@"https://resources.download.minecraft.net/%@", pathname];
        NSURLSessionDownloadTask *task =
            [self createDownloadTask:url size:size sha:hash altName:name toPath:path success:nil];
        if (task) {
            [tasks addObject:task];
        } else if (self.progress.cancelled) {
            return nil;
        }
    }
    return tasks;
}

// High-level method to download the entire version
- (void)downloadVersion:(NSDictionary *)version {
    [self prepareForDownload];
    [self downloadVersionMetadata:version success:^{
        [self downloadAssetMetadataWithSuccess:^{
            NSArray *libTasks = [self downloadClientLibraries];
            NSArray *assetTasks = [self downloadClientAssets];
            // Remove the fake byte workaround entirely. The totalUnitCount is dynamically built.
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

// For modpacks from an API
- (void)downloadModpackFromAPI:(ModpackAPI *)api
                         detail:(NSDictionary *)modDetail
                        atIndex:(NSUInteger)selectedVersion
{
    [self prepareForDownload];
    
    NSString *url = modDetail[@"versionUrls"][selectedVersion];
    NSUInteger size = [modDetail[@"versionSizes"][selectedVersion] unsignedLongLongValue];
    NSString *sha = modDetail[@"versionHashes"][selectedVersion];
    NSString *name = [[[[modDetail[@"title"] lowercaseString]
                        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]
                       stringByReplacingOccurrencesOfString:@" " withString:@"_"] copy];
    NSString *packagePath = [NSTemporaryDirectory() stringByAppendingFormat:@"/%@.zip", name];
    
    NSURLSessionDownloadTask *task =
        [self createDownloadTask:url size:size sha:sha altName:nil toPath:packagePath success:^{
            NSString *destinationPath =
                [NSString stringWithFormat:@"%s/custom_gamedir/%@", getenv("POJAV_GAME_DIR"), name];
            [api downloader:self submitDownloadTasksFromPackage:packagePath toPath:destinationPath];
        }];
    [task resume];
}

// Prepare our data for a new set of downloads
- (void)prepareForDownload {
    self.textProgress = [NSProgress new];
    self.textProgress.kind = NSProgressKindFile;
    self.textProgress.fileOperationKind = NSProgressFileOperationKindDownloading;
    self.textProgress.totalUnitCount = -1;
    
    self.progress = [NSProgress new];
    self.progress.totalUnitCount = 0; // No fake unit; total is built dynamically
    [self.fileList removeAllObjects];
    [self.progressList removeAllObjects];
}

// *** New public method implementation ***
- (void)finalizeDownloads {
    self.progress.completedUnitCount = self.progress.totalUnitCount;
    self.textProgress.completedUnitCount = self.progress.totalUnitCount;
    NSLog(@"Finalizing downloads...");
}

#pragma mark - On Error

- (void)finishDownloadWithErrorString:(NSString *)error {
    [self.progress cancel];
    [self.manager invalidateSessionCancelingTasks:YES resetSession:YES];
    showDialog(localize(@"Error", nil), error);
    self.handleError();
}

- (void)finishDownloadWithError:(NSError *)error file:(NSString *)file {
    NSString *errorStr = [NSString stringWithFormat:localize(@"launcher.mcl.error_download", NULL),
                          file, error.localizedDescription];
    NSLog(@"[MCDL] Error: %@ %@", errorStr, NSThread.callStackSymbols);
    [self finishDownloadWithErrorString:errorStr];
}

#pragma mark - Access Check

- (BOOL)checkAccessWithDialog:(BOOL)show {
    BOOL accessible = [BaseAuthenticator.current.authData[@"username"] hasPrefix:@"Demo."] ||
                   (BaseAuthenticator.current.authData[@"xboxGamertag"] != nil);
    if (!accessible) {
        [self.progress cancel];
        if (show) {
            [self finishDownloadWithErrorString:@"Minecraft can't be legally installed with a local account. Please switch to an online account."];
        }
    }
    return accessible;
}

#pragma mark - SHA Checks

- (BOOL)checkSHAIgnorePref:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName logSuccess:(BOOL)logSuccess {
    if (sha.length == 0) {
        BOOL existence = [NSFileManager.defaultManager fileExistsAtPath:path];
        if (existence) {
            NSLog(@"[MCDL] Warning: no SHA for %@, assuming okay", (altName ?: path.lastPathComponent));
        }
        return existence;
    }
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        NSLog(@"[MCDL] File does not exist for SHA check: %@", altName ?: path.lastPathComponent);
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
        NSLog(@"[MCDL] SHA1 %@ for %@ (expected: %@, got: %@)",
              check ? @"passed" : @"failed",
              altName ?: path.lastPathComponent,
              sha, localSHA);
    }
    return check;
}

- (BOOL)checkSHA:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName logSuccess:(BOOL)logSuccess {
    if (getPrefBool(@"general.check_sha")) {
        return [self checkSHAIgnorePref:sha forFile:path altName:altName logSuccess:logSuccess];
    } else {
        return [NSFileManager.defaultManager fileExistsAtPath:path];
    }
}

- (BOOL)checkSHA:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName {
    return [self checkSHA:sha forFile:path altName:altName logSuccess:(altName == nil)];
}

@end
