#import "LauncherPreferences.h"
#import "PLProfiles.h"
#import "utils.h"

static PLProfiles* current;

@implementation PLProfiles

+ (NSDictionary *)defaultProfiles {
    return [@{
        @"profiles": @{
            @"(Default)": @{
                @"name": @"(Default)",
                @"lastVersionId": @"latest-release"
            }
        },
        @"selectedProfile": @"(Default)"
    } mutableCopy];
}

+ (PLProfiles *)current {
    if (!current) {
        [self updateCurrent];
    }
    return current;
}

+ (void)updateCurrent {
    current = [[PLProfiles alloc] initWithCurrentInstance];
}

+ (NSString *)resolveKeyForCurrentProfile:(id)key {
    return [self profile:self.current.selectedProfile resolveKey:key];
}

+ (id)profile:(NSMutableDictionary *)profile resolveKey:(id)key {
    NSString *value = profile[key];
    if (value.length > 0) {
        return value;
    }
    NSDictionary *valueDefaults = @{@"javaVersion": @"0", @"gameDir": @"."};
    if (valueDefaults[key]) {
        return valueDefaults[key];
    }
    NSDictionary *prefDefaults = @{@"defaultTouchCtrl": @"control.default_ctrl", @"defaultGamepadCtrl": @"control.default_gamepad_ctrl", @"javaArgs": @"java.java_args", @"renderer": @"video.renderer"};
    return getPrefObject(prefDefaults[key]);
}

- (instancetype)initWithCurrentInstance {
    self = [super init];
    self.profilePath = [@(getenv("POJAV_GAME_DIR")) stringByAppendingPathComponent:@"launcher_profiles.json"];
    self.profileDict = parseJSONFromFile(self.profilePath);
    if (self.profileDict[@"NSErrorObject"]) {
        self.profileDict = [PLProfiles defaultProfiles];
        [self save];
    }
    return self;
}

- (NSMutableDictionary *)profiles {
    return self.profileDict[@"profiles"];
}

- (NSMutableDictionary *)selectedProfile {
    return self.profiles[self.selectedProfileName];
}

- (NSString *)selectedProfileName {
    return self.profileDict[@"selectedProfile"];
}

- (void)setSelectedProfileName:(NSString *)name {
    self.profileDict[@"selectedProfile"] = name;
    [self save];
}

- (void)save {
    saveJSONToFile(self.profileDict, self.profilePath);
}

@end
