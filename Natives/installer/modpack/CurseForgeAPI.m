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
#define CURSEFORGE_PAGINATION_SIZE 50

@interface CurseForgeAPI ()
@property (nonatomic, copy) NSString *apiKey;
@end

@implementation CurseForgeAPI

#pragma mark - Initialization

- (instancetype)initWithAPIKey:(NSString *)apiKey {
    self = [super initWithURL:@"https://api.curseforge.com/v1"];
    if (self) {
        self.apiKey = apiKey;
    }
    return self;
}

#pragma mark - Overridden GET Endpoint
// Refactored to use dispatch semaphores for synchronous network call in background thread.
- (id)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params {
    __block id result = nil;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    NSString *url = [self.baseURL stringByAppendingPathComponent:endpoint];
    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    
    NSString *key = self.apiKey;
    if (key.length == 0) {
        char *envKey = getenv("CURSEFORGE_API_KEY");
        if (envKey) {
            key = [NSString stringWithUTF8String:envKey];
        }
    }
    [manager.requestSerializer setValue:key forHTTPHeaderField:@"x-api-key"];
    
    [manager GET:url parameters:params headers:nil progress:nil
         success:^(NSURLSessionTask *task, id obj) {
             result = obj;
             dispatch_semaphore_signal(semaphore);
         }
         failure:^(NSURLSessionTask *operation, NSError *error) {
             self.lastError = error;
             dispatch_semaphore_signal(semaphore);
         }];
    dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
    return result;
}

#pragma mark - Asynchronous API Methods

- (void)searchModWithFilters:(NSDictionary *)searchFilters
         previousPageResult:(NSMutableArray *)prevResult
                 completion:(void (^ _Nonnull)(NSMutableArray * _Nullable results, NSError * _Nullable error))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        int limit = CURSEFORGE_PAGINATION_SIZE;
        NSString *query = searchFilters[@"name"] ?: @"";
        NSMutableDictionary *params = [@{
            @"gameId": @(kCurseForgeGameIDMinecraft),
            @"classId": ([searchFilters[@"isModpack"] boolValue] ? @(kCurseForgeClassIDModpack) : @(kCurseForgeClassIDMod)),
            @"searchFilter": query,
            @"sortField": @(1),
            @"sortOrder": @"desc",
            @"pageSize": @(limit),
            @"index": @(prevResult.count)
        } mutableCopy];
        
        if (searchFilters[@"mcVersion"] && [searchFilters[@"mcVersion"] length] > 0) {
            params[@"gameVersion"] = searchFilters[@"mcVersion"];
        }
        
        NSDictionary *response = [self getEndpoint:@"mods/search" params:params];
        if (!response) {
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(nil, self.lastError);
                });
            }
            return;
        }
        
        NSMutableArray *result = prevResult ?: [NSMutableArray new];
        NSArray *data = response[@"data"];
        for (NSDictionary *mod in data) {
            id allow = mod[@"allowModDistribution"];
            if (allow && ![allow isKindOfClass:[NSNull class]] && ![allow boolValue]) {
                continue;
            }
            BOOL isModpack = ([mod[@"classId"] integerValue] == kCurseForgeClassIDModpack);
            NSMutableDictionary *entry = [@{
                @"apiSource": @(1),
                @"isModpack": @(isModpack),
                @"id": [NSString stringWithFormat:@"%@", mod[@"id"]],
                @"title": (mod[@"name"] ? [NSString stringWithFormat:@"%@", mod[@"name"]] : @""),
                @"description": (mod[@"summary"] ? [NSString stringWithFormat:@"%@", mod[@"summary"]] : @""),
                @"imageUrl": (mod[@"logo"] ? [NSString stringWithFormat:@"%@", mod[@"logo"]] : @"")
            } mutableCopy];
            [result addObject:entry];
        }
        
        NSDictionary *pagination = response[@"pagination"];
        NSUInteger totalCount = [pagination[@"totalCount"] unsignedIntegerValue];
        self.reachedLastPage = (result.count >= totalCount);
        
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(result, nil);
        });
    });
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item
              completion:(void (^ _Nonnull)(NSError * _Nullable error))completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *modId = [NSString stringWithFormat:@"%@", item[@"id"]];
        NSDictionary *response = [self getEndpoint:[NSString stringWithFormat:@"mods/%@/files", modId] params:nil];
        if (!response) {
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(self.lastError);
                });
            }
            return;
        }
        NSArray *files = response[@"data"];
        NSMutableArray *names = [NSMutableArray new];
        NSMutableArray *mcNames = [NSMutableArray new];
        NSMutableArray *urls = [NSMutableArray new];
        NSMutableArray *hashes = [NSMutableArray new];
        NSMutableArray *sizes = [NSMutableArray new];
        
        for (NSDictionary *file in files) {
            [names addObject:[NSString stringWithFormat:@"%@", file[@"fileName"] ?: @""]];
            id versions = file[@"gameVersion"] ?: file[@"gameVersionList"];
            NSString *gameVersion = @"";
            if ([versions isKindOfClass:[NSArray class]] && [versions count] > 0) {
                gameVersion = [NSString stringWithFormat:@"%@", ((NSArray *)versions)[0]];
            } else if ([versions isKindOfClass:[NSString class]]) {
                gameVersion = [NSString stringWithFormat:@"%@", versions];
            }
            [mcNames addObject:gameVersion];
            [urls addObject:[NSString stringWithFormat:@"%@", file[@"downloadUrl"] ?: @""]];
            
            NSNumber *sizeNumber = nil;
            id fileLength = file[@"fileLength"];
            if ([fileLength isKindOfClass:[NSNumber class]]) {
                sizeNumber = fileLength;
            } else if ([fileLength isKindOfClass:[NSString class]]) {
                sizeNumber = @([fileLength unsignedLongLongValue]);
            } else {
                sizeNumber = @(0);
            }
            [sizes addObject:sizeNumber];
            
            NSString *sha1 = @"";
            NSArray *hashesArray = file[@"hashes"];
            for (NSDictionary *hashDict in hashesArray) {
                if ([[NSString stringWithFormat:@"%@", hashDict[@"algo"]] isEqualToString:@"SHA1"]) {
                    sha1 = [NSString stringWithFormat:@"%@", hashDict[@"value"]];
                    break;
                }
            }
            [hashes addObject:sha1];
        }
        
        item[@"versionNames"] = names;
        item[@"mcVersionNames"] = mcNames;
        item[@"versionUrls"] = urls;
        item[@"versionHashes"] = hashes;
        item[@"versionSizes"] = sizes;
        item[@"versionDetailsLoaded"] = @(YES);
        
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil);
        });
    });
}

- (void)installModpackFromDetail:(NSDictionary *)modDetail
                         atIndex:(NSUInteger)selectedVersion
                      completion:(void (^ _Nonnull)(NSError * _Nullable error))completion {
    NSArray *versionNames = modDetail[@"versionNames"];
    if (selectedVersion >= versionNames.count) {
        if (completion) {
            NSError *error = [NSError errorWithDomain:@"CurseForgeAPIErrorDomain"
                                                 code:100
                                             userInfo:@{NSLocalizedDescriptionKey: @"Selected version index is out of bounds."}];
            completion(error);
        }
        return;
    }
    [super installModpackFromDetail:modDetail atIndex:selectedVersion];
    if (completion) {
        completion(nil);
    }
}

@end
