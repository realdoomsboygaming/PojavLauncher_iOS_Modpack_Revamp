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
        self.previousOffset = 0; // Start pagination at zero
    }
    return self;
}

- (BOOL)extractDirectory:(NSString *)directory fromArchive:(UZKArchive *)archive toPath:(NSString *)destPath error:(NSError **)error {
    // Get the list of filenames inside the archive
    NSArray<NSString *> *filenames = [archive listFilenames:error];
    if (!filenames) {
        return NO; // Return failure if we couldn't list files
    }

    BOOL success = YES;
    NSFileManager *fileManager = [NSFileManager defaultManager];

    for (NSString *filename in filenames) {
        // Only extract files inside the given subdirectory
        if ([filename hasPrefix:directory]) {
            NSString *fullPath = [destPath stringByAppendingPathComponent:filename];
            NSString *parentDir = [fullPath stringByDeletingLastPathComponent];

            // Ensure parent directory exists before extracting the file
            [fileManager createDirectoryAtPath:parentDir withIntermediateDirectories:YES attributes:nil error:nil];

            // Extract file contents
            NSData *fileData = [archive extractDataFromFile:filename error:error];
            if (!fileData) {
                success = NO;
                break; // Stop on failure
            }

            // Write file to the destination path
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

    // Extract and parse manifest.json
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

    // Extract the entire archive contents if necessary
    [archive extractFilesTo:destPath overwrite:YES error:&error];
    if (error) {
        NSLog(@"Failed to extract modpack: %@", error.localizedDescription);
        return;
    }

    // Delete the ZIP after extraction
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
