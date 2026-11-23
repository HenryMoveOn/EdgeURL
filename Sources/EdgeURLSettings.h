// SPDX-License-Identifier: MIT
//
// The values the tweak reads from the local.apelin.edgeurl preferences domain,
// clamped to the ranges the settings pane offers. Keys and defaults are the
// old version's, plus MinimumTravel and Animated.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface EdgeURLSettings : NSObject
@property (nonatomic, readonly) BOOL enabled;
@property (nonatomic, readonly) BOOL leftEdge;
@property (nonatomic, readonly) BOOL rightEdge;
@property (nonatomic, readonly) BOOL showArea;
@property (nonatomic, readonly) BOOL animated;
/// A light tap of the Taptic Engine the moment a swipe commits and the URL is
/// about to open.
@property (nonatomic, readonly) BOOL haptic;
@property (nonatomic, readonly) CGFloat edgeWidth;
@property (nonatomic, readonly) CGFloat regionTop;
@property (nonatomic, readonly) CGFloat regionHeight;
@property (nonatomic, readonly) CGFloat threshold;
@property (nonatomic, readonly) CGFloat minimumTravel;
@property (nonatomic, readonly) CGFloat areaAlpha;
/// The system gesture slot the pan is registered in. Not in the settings
/// pane; a slot another tweak already took is what this is for.
@property (nonatomic, readonly) NSUInteger gestureType;
@property (nonatomic, readonly, copy) NSString *URLString;
@property (nonatomic, readonly, strong, nullable) NSURL *URL;

+ (instancetype)currentSettings;
- (NSString *)summary;
@end

CGFloat EdgeURLClamp(CGFloat value, CGFloat low, CGFloat high);

NS_ASSUME_NONNULL_END