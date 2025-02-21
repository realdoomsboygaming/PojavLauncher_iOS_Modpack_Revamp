#import <CommonCrypto/CommonDigest.h>
#import "authenticator/BaseAuthenticator.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "MinecraftResourceUtils.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

@implementation MinecraftResourceUtils

+ (void)processVersion:(NSMutableDictionary *)json inheritsFrom:(NSMutableDictionary *)inheritsFrom {
    [self insertSafety:inheritsFrom from:json arr:@[@"assetIndex", @"assets", @"id", @"inheritsFrom", @"mainClass", @"minecraftArguments", @"optifineLib", @"releaseTime", @"time", @"type"]];
    inheritsFrom[@"arguments"] = json[@"arguments"];
    for (NSMutableDictionary *lib in json[@"libraries"]) {
        NSString *libName = [lib[@"name"] substringToIndex:[lib[@"name"] rangeOfString:@":" options:NSBackwardsSearch].location];
        BOOL found = NO;
        for (NSInteger i = 0; i < [inheritsFrom[@"libraries"] count]; i++) {
            NSMutableDictionary *libAdded = inheritsFrom[@"libraries"][i];
            NSString *libAddedName = [libAdded[@"name"] substringToIndex:[libAdded[@"name"] rangeOfString:@":" options:NSBackwardsSearch].location];
            if ([libAdded[@"name"] hasPrefix:libName]) {
                inheritsFrom[@"libraries"][i] = lib;
                found = YES;
                break;
            }
        }
        if (!found) {
            [inheritsFrom[@"libraries"] addObject:lib];
        }
    }
}

+ (void)insertSafety:(NSMutableDictionary *)targetVer from:(NSDictionary *)fromVer arr:(NSArray *)arr {
    for (NSString *key in arr) {
        if (([fromVer[key] isKindOfClass:[NSString class]] && [fromVer[key] length] > 0) || targetVer[key] == nil) {
            targetVer[key] = fromVer[key];
        } else {
            NSLog(@"[MCDL] insertSafety: how to insert %@?", key);
        }
    }
}

+ (NSInteger)numberOfArgsToSkipForArg:(NSString *)arg {
    if (![arg isKindOfClass:[NSString class]]) {
        return 1;
    } else if ([arg hasPrefix:@"-cp"]) {
        return 2;
    } else if ([arg hasPrefix:@"-Djava.library.path="]) {
        return 1;
    } else if ([arg hasPrefix:@"-XX:HeapDumpPath"]) {
        return 1;
    } else {
        return 0;
    }
}

+ (void)tweakVersionJson:(NSMutableDictionary *)json {
    for (NSMutableDictionary *library in json[@"libraries"]) {
        library[@"skip"] = @([library[@"downloads"][@"classifiers"] != nil || library[@"natives"] != nil || [library[@"name"] hasPrefix:@"org.lwjgl"]);
        NSString *versionStr = [library[@"name"] componentsSeparatedByString:@":"][2];
        NSArray<NSString *> *versionComponents = [versionStr componentsSeparatedByString:@"."];
        if ([library[@"name"] hasPrefix:@"net.java.dev.jna:jna:"]) {
            uint32_t bundledVer = (5 << 16) | (13 << 8) | 0;
            uint32_t requiredVer = (uint32_t)([versionComponents[0] intValue] << 16 | [versionComponents[1] intValue] << 8 | [versionComponents[2] intValue]);
            if (requiredVer > bundledVer) {
                NSLog(@"[MCDL] Warning: JNA version required by %@ is %@ > 5.13.0", json[@"id"], versionStr);
                continue;
            }
            library[@"name"] = @"net.java.dev.jna:jna:5.13.0";
            library[@"downloads"][@"artifact"][@"path"] = @"net/java/dev/jna/jna/5.13.0/jna-5.13.0.jar";
            library[@"downloads"][@"artifact"][@"url"] = @"https://repo1.maven.org/maven2/net/java/dev/jna/jna/5.13.0/jna-5.13.0.jar";
            library[@"downloads"][@"artifact"][@"sha1"] = @"1200e7ebeedbe0d10062093f32925a912020e747";
        } else if ([library[@"name"] hasPrefix:@"org.ow2.asm:asm-all:"]) {
            if ([versionComponents[0] intValue] >= 5) continue;
            library[@"name"] = @"org.ow2.asm:asm-all:5.0.4";
            library[@"downloads"][@"artifact"][@"path"] = @"org/ow2/asm/asm-all/5.0.4/asm-all-5.0.4.jar";
            library[@"downloads"][@"artifact"][@"sha1"] = @"e6244859997b3d4237a552669279780876228909";
            library[@"downloads"][@"artifact"][@"url"] = @"https://repo1.maven.org/maven2/org/ow2/asm/asm-all/5.0.4/asm-all-5.0.4.jar";
        }
    }
    NSMutableDictionary *client = [NSMutableDictionary new];
    client[@"downloads"] = [NSMutableDictionary new];
    if (json[@"downloads"][@"client"] == nil) {
        client[@"downloads"][@"artifact"] = [NSMutableDictionary new];
        client[@"skip"] = @YES;
    } else {
        client[@"downloads"][@"artifact"] = json[@"downloads"][@"client"];
    }
    client[@"downloads"][@"artifact"][@"path"] = [NSString stringWithFormat:@"../versions/%@/%@.jar", json[@"id"], json[@"id"]];
    client[@"name"] = [NSString stringWithFormat:@"%@.jar", json[@"id"]];
    [json[@"libraries"] addObject:client];
    if (json[@"inheritsFrom"] == nil || json[@"arguments"][@"jvm"] == nil) return;
    json[@"arguments"][@"jvm_processed"] = [NSMutableArray new];
    NSDictionary *varArgMap = @{@"${classpath_separator}": @":", @"${library_directory}": [NSString stringWithFormat:@"%s/libraries", getenv("POJAV_GAME_DIR")], @"${version_name}": json[@"id"]};
    int argsToSkip = 0;
    for (NSString *arg in json[@"arguments"][@"jvm"]) {
        if (argsToSkip == 0) {
            argsToSkip = [self numberOfArgsToSkipForArg:arg];
        }
        if (argsToSkip == 0) {
            NSString *argStr = arg;
            for (NSString *key in varArgMap) {
                argStr = [argStr stringByReplacingOccurrencesOfString:key withString:varArgMap[key]];
            }
            [json[@"arguments"][@"jvm_processed"] addObject:argStr];
        } else {
            argsToSkip--;
        }
    }
}

+ (NSObject *)findVersion:(NSString *)version inList:(NSArray *)list {
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"(id == %@)", version];
    return [list filteredArrayUsingPredicate:predicate].firstObject;
}

+ (NSObject *)findNearestVersion:(NSObject *)version expectedType:(int)type {
    if (type != TYPE_RELEASE && type != TYPE_SNAPSHOT) return nil;
    if ([version isKindOfClass:[NSString class]]) {
        NSDictionary *versionDict = parseJSONFromFile([NSString stringWithFormat:@"%s/versions/%@/%@.json", getenv("POJAV_GAME_DIR"), version, version]);
        NSAssert(versionDict != nil, @"version should not be null");
        if (versionDict[@"inheritsFrom"] == nil) return nil;
        NSObject *inheritsFrom = [self findVersion:versionDict[@"inheritsFrom"] inList:remoteVersionList];
        return type == TYPE_RELEASE ? inheritsFrom : [self findNearestVersion:inheritsFrom expectedType:type];
    }
    NSString *versionType = [version valueForKey:@"type"];
    NSInteger index = [remoteVersionList indexOfObject:(NSDictionary *)version];
    if ([versionType isEqualToString:@"release"] && type == TYPE_SNAPSHOT) {
        NSDictionary *result = remoteVersionList[index + 1];
        if ([result[@"type"] isEqualToString:@"release"]) {
            return [self findNearestVersion:result expectedType:type];
        }
        return result;
    } else if ([versionType isEqualToString:@"snapshot"] && type == TYPE_RELEASE) {
        while (remoteVersionList.count > labs(index)) {
            NSDictionary *result = remoteVersionList[labs(index)];
            if ([result[@"type"] isEqualToString:@"release"]) return result;
            index--;
        }
    }
    return nil;
}

@end
