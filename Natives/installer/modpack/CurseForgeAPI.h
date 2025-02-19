#ifndef CurseForgeAPI_h
#define CurseForgeAPI_h

#import <Foundation/Foundation.h>

@interface CurseForgeAPI : NSObject

@property (nonatomic, strong, readonly) NSString *apiKey;
@property (nonatomic, strong) NSError *lastError;
@property (nonatomic, assign) NSInteger previousOffset;
@property (nonatomic, assign) BOOL reachedLastPage;
@property (nonatomic, strong) NSString *lastSearchTerm;

- (instancetype)initWithAPIKey:(NSString *)apiKey;
- (NSString *)loadAPIKey;
- (id)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params;
- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, id> *)searchFilters previousPageResult:(NSMutableArray *)previousResults;
- (void)installModpackFromDetail:(NSDictionary *)detail atIndex:(NSInteger)index;
- (void)loadDetailsOfMod:(NSMutableDictionary *)item;

@end

#endif /* CurseForgeAPI_h */
