#ifndef CurseForgeAPI_h
#define CurseForgeAPI_h

#import <Foundation/Foundation.h>

@interface CurseForgeAPI : NSObject

@property (nonatomic, strong, readonly) NSString *apiKey;
@property (nonatomic, strong) NSError *lastError;
@property (nonatomic, assign) NSInteger previousOffset;
@property (nonatomic, assign) BOOL reachedLastPage;
@property (nonatomic, strong) NSString *lastSearchTerm;

/// Initialize with a CurseForge API key (loaded from user defaults or environment).
- (instancetype)initWithAPIKey:(NSString *)apiKey;

/// Load from environment variable if not specified.
- (NSString *)loadAPIKey;

/// Generic method to call the CurseForge endpoint.
- (id)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params;

/// Search for a mod or modpack with filters
- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, id> *)searchFilters
                      previousPageResult:(NSMutableArray *)previousResults;

/// Install modpack from detail. 
- (void)installModpackFromDetail:(NSDictionary *)detail atIndex:(NSInteger)index;

/// Pre-load version details. 
- (void)loadDetailsOfMod:(NSMutableDictionary *)item;

@end

#endif /* CurseForgeAPI_h */
