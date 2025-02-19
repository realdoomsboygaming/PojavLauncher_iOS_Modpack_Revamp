#import <Foundation/Foundation.h>
#import "MinecraftResourceDownloadTask.h"
#import <AFNetworking/AFHTTPSessionManager.h>

@interface CurseForgeAPI : AFHTTPSessionManager 

@property (nonatomic) BOOL reachedLastPage;
@property (nonatomic) NSInteger previousOffset;
@property (nonatomic, strong) NSString *lastSearchTerm;
@property (nonatomic, strong) NSString *apiKey;
@property (nonatomic, strong) NSError *lastError;

- (instancetype)initWithAPIKey:(NSString *)apiKey;
- (NSString *)loadAPIKey;
- (id)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params;
- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, id> *)searchFilters previousPageResult:(NSMutableArray *)previousResults;
- (void)installModpackFromDetail:(NSDictionary *)detail atIndex:(NSInteger)index;
- (void)loadDetailsOfMod:(NSMutableDictionary *)item;

@end
