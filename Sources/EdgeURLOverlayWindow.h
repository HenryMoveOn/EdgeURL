#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// SpringBoard's own window, above everything the desktop draws, and it does both
// jobs at once, the way HomeBarURL's does.
//
// The display view is a full-screen view that never takes a touch: it draws the
// trigger band and the wave. The sensing views are one transparent view per
// enabled edge, exactly the band's own rect.
//
// -hitTest: answers a sensing view for a point inside it and nil for every other
// point on the screen. A window that says no is skipped and the point goes to
// whatever is under it — an icon, the page, another tweak's window — so only the
// band itself is ever taken from the desktop.
extern const UIWindowLevel EdgeURLOverlayWindowLevel;

@interface EdgeURLOverlayWindow : UIWindow

/// Draws the band and the wave; never the target of a touch.
@property (nonatomic, weak, nullable) UIView *displayView;
/// The rects of the sensing areas, as direct subviews in window coordinates.
@property (nonatomic, copy) NSArray<UIView *> *sensingViews;

@end

NS_ASSUME_NONNULL_END
