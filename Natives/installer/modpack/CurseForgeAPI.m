#import "CurseForgeAPI.h"
#import "UZKArchive.h"
#import "ModpackUtils.h"
#import "PLProfiles.h"

@implementation CurseForgeAPI

#pragma mark - Install a modpack (inline approach)

- (void)installModpackFromDetail:(NSDictionary *)detail atIndex:(NSInteger)index
{
    // 1) Validate input
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

    NSString *tempDir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"curseforge_install"];
    [[NSFileManager defaultManager] createDirectoryAtPath:tempDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    NSString *zipPath = [tempDir stringByAppendingPathComponent:@"modpack.zip"];

    __block NSError *downloadError = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    NSURLSessionDownloadTask *task = [[NSURLSession sharedSession]
       downloadTaskWithURL:zipUrl
         completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error)
    {
        if (error) {
            downloadError = error;
        } else {
            // Move the downloaded temp file to zipPath
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

    NSError *overridesError = nil;
    [ModpackUtils archive:archive extractDirectory:@"overrides" toPath:tempDir error:&overridesError];
    [ModpackUtils archive:archive extractDirectory:@"Overrides" toPath:tempDir error:&overridesError];
    if (overridesError) {
        NSLog(@"[CurseForgeAPI] Could not extract overrides: %@", overridesError.localizedDescription);
    }

    [[NSFileManager defaultManager] removeItemAtPath:zipPath error:nil];

    NSString *packName = [manifest[@"name"] isKindOfClass:[NSString class]] ? manifest[@"name"] : @"CF_Pack";
    NSString *finalInstallPath = [NSTemporaryDirectory() stringByAppendingPathComponent:packName];

    NSError *moveAllError = nil;
    [[NSFileManager defaultManager] moveItemAtPath:tempDir
                                            toPath:finalInstallPath
                                             error:&moveAllError];
    if (moveAllError) {
        NSLog(@"[CurseForgeAPI] Could not rename temp folder: %@", moveAllError.localizedDescription);
        return;
    }

    NSDictionary *mcSection = manifest[@"minecraft"];
    NSString *profileVersionID = @"";
    if ([mcSection isKindOfClass:[NSDictionary class]]) {
        NSArray *loaders = mcSection[@"modLoaders"];
        if ([loaders isKindOfClass:[NSArray class]] && loaders.count > 0) {
            NSDictionary *firstLoader = loaders.firstObject;
            if ([firstLoader[@"id"] isKindOfClass:[NSString class]]) {
                // e.g. "forge-xx.xx.xx"
                profileVersionID = firstLoader[@"id"];
            }
        }
    }

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
