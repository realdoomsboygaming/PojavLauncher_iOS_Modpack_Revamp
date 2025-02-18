#import <Foundation/Foundation.h>

@interface CurseForgeAPI : NSObject

- (instancetype)init;
- (void)getModDetailsWithModId:(NSInteger)modId completion:(void (^)(NSDictionary *modDetails, NSError *error))completion;
- (void)searchModsWithFilters:(NSDictionary *)filters completion:(void (^)(NSArray *mods, NSError *error))completion;
- (void)installModpackWithModpackId:(NSInteger)modpackId completion:(void (^)(BOOL success, NSError *error))completion;

@end

@implementation CurseForgeAPI

- (instancetype)init {
    self = [super init];
    if (self) {
        // No API key needed, so no initialization for apiKey
    }
    return self;
}

// Helper method to perform GET request
- (void)performGETRequestWithURL:(NSURL *)url completion:(void (^)(NSData *data, NSError *error))completion {
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            NSLog(@"GET request failed: %@", error.localizedDescription);
            completion(nil, error);
            return;
        }
        if (!data) {
            NSError *noDataError = [NSError errorWithDomain:@"CurseForgeAPI" code:1001 userInfo:@{NSLocalizedDescriptionKey: @"No data received"}];
            completion(nil, noDataError);
            return;
        }
        completion(data, nil);
    }];
    [task resume];
}

// Helper method to perform POST request
- (void)performPOSTRequestWithURL:(NSURL *)url parameters:(NSDictionary *)parameters completion:(void (^)(NSData *data, NSError *error))completion {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    
    NSError *jsonError;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:parameters options:0 error:&jsonError];
    if (jsonError) {
        NSLog(@"Error serializing parameters: %@", jsonError.localizedDescription);
        completion(nil, jsonError);
        return;
    }
    [request setHTTPBody:jsonData];
    
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            NSLog(@"POST request failed: %@", error.localizedDescription);
            completion(nil, error);
            return;
        }
        if (!data) {
            NSError *noDataError = [NSError errorWithDomain:@"CurseForgeAPI" code:1001 userInfo:@{NSLocalizedDescriptionKey: @"No data received"}];
            completion(nil, noDataError);
            return;
        }
        completion(data, nil);
    }];
    [task resume];
}

// Fetch mod details
- (void)getModDetailsWithModId:(NSInteger)modId completion:(void (^)(NSDictionary *modDetails, NSError *error))completion {
    NSString *urlString = [NSString stringWithFormat:@"https://api.curseforge.com/v1/mods/%ld", (long)modId];
    NSURL *url = [NSURL URLWithString:urlString];
    
    [self performGETRequestWithURL:url completion:^(NSData *data, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        
        NSError *jsonError;
        NSDictionary *modDetails = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError) {
            NSLog(@"Error parsing mod details: %@", jsonError.localizedDescription);
            completion(nil, jsonError);
            return;
        }
        
        // Ensure UI updates happen on the main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(modDetails, nil);
        });
    }];
}

// Search for mods with filters
- (void)searchModsWithFilters:(NSDictionary *)filters completion:(void (^)(NSArray *mods, NSError *error))completion {
    NSString *urlString = @"https://api.curseforge.com/v1/mods/search";
    NSURL *url = [NSURL URLWithString:urlString];
    
    [self performPOSTRequestWithURL:url parameters:filters completion:^(NSData *data, NSError *error) {
        if (error) {
            completion(nil, error);
            return;
        }
        
        NSError *jsonError;
        NSDictionary *response = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError) {
            NSLog(@"Error parsing mod search response: %@", jsonError.localizedDescription);
            completion(nil, jsonError);
            return;
        }
        
        NSArray *mods = response[@"mods"];
        
        // Ensure UI updates happen on the main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(mods, nil);
        });
    }];
}

// Install modpack
- (void)installModpackWithModpackId:(NSInteger)modpackId completion:(void (^)(BOOL success, NSError *error))completion {
    NSString *urlString = [NSString stringWithFormat:@"https://api.curseforge.com/v1/modpacks/%ld/install", (long)modpackId];
    NSURL *url = [NSURL URLWithString:urlString];
    
    NSDictionary *parameters = @{@"modpackId": @(modpackId)};
    
    [self performPOSTRequestWithURL:url parameters:parameters completion:^(NSData *data, NSError *error) {
        if (error) {
            completion(NO, error);
            return;
        }
        
        NSError *jsonError;
        NSDictionary *response = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError) {
            NSLog(@"Error parsing modpack install response: %@", jsonError.localizedDescription);
            completion(NO, jsonError);
            return;
        }
        
        BOOL success = [response[@"success"] boolValue];
        
        // Ensure UI updates happen on the main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(success, nil);
        });
    }];
}

@end
