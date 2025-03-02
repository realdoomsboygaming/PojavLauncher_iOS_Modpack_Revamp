#import "AFNetworking.h"
#import "MinecraftResourceDownloadTask.h"
#import "ModpackAPI.h"
#import "utils.h"

@implementation ModpackAPI

#pragma mark - Interface methods

- (instancetype)initWithURL:(NSString *)url {
    self = [super init];
    self.baseURL = url;
    return self;
}

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    [self doesNotRecognizeSelector:_cmd];
}

- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, NSString *> *)searchFilters previousPageResult:(NSMutableArray *)prevResult {
    [self doesNotRecognizeSelector:_cmd];
    return nil;
}

- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath {
    [self doesNotRecognizeSelector:_cmd];
}

- (id)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params {
    __block id result;
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);
    NSString *url = [self.baseURL stringByAppendingPathComponent:endpoint];
    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    [manager GET:url parameters:params headers:nil progress:nil success:^(NSURLSessionTask *task, id responseObject) {
        result = responseObject;
        dispatch_group_leave(group);
    } failure:^(NSURLSessionTask *operation, NSError *error) {
        self.lastError = error;
        dispatch_group_leave(group);
    }];
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    return result;
}

- (void)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params completion:(void (^)(id result, NSError *error))completion {
    NSString *url = [self.baseURL stringByAppendingPathComponent:endpoint];
    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    [manager GET:url parameters:params headers:nil progress:nil success:^(NSURLSessionTask *task, id responseObject) {
        if (completion) completion(responseObject, nil);
    } failure:^(NSURLSessionTask *operation, NSError *error) {
        self.lastError = error;
        if (completion) completion(nil, error);
    }];
}

- (void)installModpackFromDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion {
    NSDictionary* userInfo = @{
        @"detail": modDetail,
        @"index": @(selectedVersion)
    };
    [NSNotificationCenter.defaultCenter postNotificationName:@"InstallModpack" object:self userInfo:userInfo];
}

@end
