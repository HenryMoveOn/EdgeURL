// SPDX-License-Identifier: MIT
//
// Reads local.apelin.edgeurl through CFPreferences, one value at a time,
// falling back to the coded default the settings pane shows for a missing key.
#import "EdgeURLSettings.h"

static NSString *EdgeURLDomain(void) {
    return @APELIN_PACKAGE_ID;
}

CGFloat EdgeURLClamp(CGFloat value, CGFloat low, CGFloat high) {
    if (value < low) {
        return low;
    }
    if (value > high) {
        return high;
    }
    return value;
}

static id EdgeURLCopyValue(NSString *key) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)EdgeURLDomain());
    return value != NULL ? CFBridgingRelease(value) : nil;
}

static double EdgeURLReadNumber(NSString *key, double fallback) {
    id value = EdgeURLCopyValue(key);
    if ([value isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)value doubleValue];
    }
    if ([value isKindOfClass:[NSString class]]) {
        return [(NSString *)value doubleValue];
    }
    return fallback;
}

static BOOL EdgeURLReadBool(NSString *key, BOOL fallback) {
    id value = EdgeURLCopyValue(key);
    if ([value isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)value boolValue];
    }
    if ([value isKindOfClass:[NSString class]]) {
        return [(NSString *)value boolValue];
    }
    return fallback;
}

static NSString *EdgeURLReadString(NSString *key, NSString *fallback) {
    id value = EdgeURLCopyValue(key);
    if ([value isKindOfClass:[NSString class]]) {
        return value;
    }
    return fallback;
}

// "" and whitespace open nothing; a bare address such as example.com is tried
// as https, which is what the settings pane promises.
static NSURL *EdgeURLParseURL(NSString *raw) {
    NSString *trimmed = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        return nil;
    }
    NSURL *url = [NSURL URLWithString:trimmed];
    if (url == nil || url.scheme.length == 0) {
        url = [NSURL URLWithString:[@"https://" stringByAppendingString:trimmed]];
    }
    if (url == nil || url.scheme.length == 0) {
        return nil;
    }
    return url;
}

@implementation EdgeURLSettings

+ (instancetype)currentSettings {
    EdgeURLSettings *settings = [[EdgeURLSettings alloc] init];
    settings->_enabled = EdgeURLReadBool(@"Enabled", YES);
    settings->_leftEdge = EdgeURLReadBool(@"LeftEdge", NO);
    settings->_rightEdge = EdgeURLReadBool(@"RightEdge", YES);
    settings->_showArea = EdgeURLReadBool(@"ShowArea", YES);
    settings->_animated = EdgeURLReadBool(@"Animated", YES);
    settings->_edgeWidth = EdgeURLClamp((CGFloat)EdgeURLReadNumber(@"EdgeWidth", 32.0), 10.0, 80.0);
    settings->_regionTop = EdgeURLClamp((CGFloat)EdgeURLReadNumber(@"RegionTop", 0.0), 0.0, 90.0);
    settings->_regionHeight = EdgeURLClamp((CGFloat)EdgeURLReadNumber(@"RegionHeight", 100.0), 10.0, 100.0);
    settings->_threshold = EdgeURLClamp((CGFloat)EdgeURLReadNumber(@"Threshold", 30.0), 4.0, 150.0);
    settings->_minimumTravel = EdgeURLClamp((CGFloat)EdgeURLReadNumber(@"MinimumTravel", 8.0), 0.0, 60.0);
    settings->_areaAlpha = EdgeURLClamp((CGFloat)EdgeURLReadNumber(@"AreaAlpha", 0.2), 0.0, 1.0);
    settings->_gestureType = (NSUInteger)EdgeURLClamp((CGFloat)EdgeURLReadNumber(@"GestureType", 0.0), 0.0, 31.0);
    settings->_URLString = [EdgeURLReadString(@"URL", @"") copy];
    settings->_URL = EdgeURLParseURL(settings->_URLString);
    return settings;
}

- (NSString *)summary {
    return [NSString stringWithFormat:
            @"enabled=%d left=%d right=%d width=%.1f top=%.1f height=%.1f threshold=%.1f minTravel=%.1f animated=%d showArea=%d alpha=%.2f type=%lu url=%@",
            self.enabled, self.leftEdge, self.rightEdge,
            self.edgeWidth, self.regionTop, self.regionHeight,
            self.threshold, self.minimumTravel,
            self.animated, self.showArea, self.areaAlpha,
            (unsigned long)self.gestureType,
            self.URL.absoluteString ?: @"(none)"];
}

@end