// SPDX-License-Identifier: MIT
//
// The settings pane. PSListController reads and writes the rows of Root.plist
// and Area.plist in the local.apelin.edgeurl domain, and each row posts
// local.apelin.edgeurl/changed, which is what the tweak listens for.
#import <Preferences/PSListController.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import <objc/message.h>

@interface EdgeURLPrefsRootListController : PSListController <UIGestureRecognizerDelegate>
@end

static NSString *EdgeURLPrefsDomain(void) {
    return @APELIN_PACKAGE_ID;
}

// The values a fresh install has, and what Restore Defaults puts back: the
// same ones the tweak falls back to.
static NSDictionary *EdgeURLPrefsDefaults(void) {
    return @{
        @"Enabled" : @YES,
        @"URL" : @"",
        @"LeftEdge" : @NO,
        @"RightEdge" : @YES,
        @"EdgeWidth" : @32,
        @"RegionTop" : @0,
        @"RegionHeight" : @100,
        @"Threshold" : @30,
        @"MinimumTravel" : @8,
        @"Animated" : @YES,
        @"Haptic" : @YES,
        @"ShowArea" : @YES,
        @"AreaAlpha" : @0.2,
    };
}

static void EdgeURLPrefsPostChanged(void) {
    notify_post(APELIN_PACKAGE_ID "/changed");
}

#pragma mark - Typing a value into a slider

// A slider row shows its number, and that number is what the finger can tap: it
// is drawn by the framework, so the cell is searched for a label holding nothing
// but a number (a percentage sign allowed) and for the slider beside it.
//
// A row's specifier is read through the cell that displays it. The framework's
// PSTableCell has the accessor; it is declared here because Apelin's own
// Preferences header stops at PSSpecifier.
@interface UITableViewCell (EdgeURLSpecifier)
- (PSSpecifier *)specifier;
@end

// Told apart from any recognizer the framework put on a cell.
@interface EdgeURLValueTapRecognizer : UITapGestureRecognizer
@end

@implementation EdgeURLValueTapRecognizer
@end

@interface EdgeURLValuePressRecognizer : UILongPressGestureRecognizer
@end

@implementation EdgeURLValuePressRecognizer
@end

static BOOL EdgeURLTextIsNumber(NSString *text) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        return NO;
    }
    if ([trimmed hasSuffix:@"%"]) {
        trimmed = [[trimmed substringToIndex:trimmed.length - 1]
                      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    if (trimmed.length == 0) {
        return NO;
    }
    NSScanner *scanner = [NSScanner scannerWithString:trimmed];
    double value = 0.0;
    if (![scanner scanDouble:&value]) {
        return NO;
    }
    return scanner.isAtEnd;
}

static UILabel *EdgeURLNumberLabelInView(UIView *view) {
    if ([view isKindOfClass:[UILabel class]] &&
        EdgeURLTextIsNumber(((UILabel *)view).text)) {
        return (UILabel *)view;
    }
    for (UIView *subview in view.subviews) {
        UILabel *found = EdgeURLNumberLabelInView(subview);
        if (found != nil) {
            return found;
        }
    }
    return nil;
}

static UISlider *EdgeURLSliderInView(UIView *view) {
    if ([view isKindOfClass:[UISlider class]]) {
        return (UISlider *)view;
    }
    for (UIView *subview in view.subviews) {
        UISlider *found = EdgeURLSliderInView(subview);
        if (found != nil) {
            return found;
        }
    }
    return nil;
}

@implementation EdgeURLPrefsRootListController

- (NSArray *)specifiers {
    if (_specifiers == nil) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)restoreDefaults:(PSSpecifier *)specifier {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"Restore Defaults"
                                           message:@"Every Edge URL setting goes back to its default value."
                                    preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Restore"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        (void)action;
        [weakSelf writeDefaults];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)writeDefaults {
    CFStringRef domain = (__bridge CFStringRef)EdgeURLPrefsDomain();
    NSDictionary *defaults = EdgeURLPrefsDefaults();
    for (NSString *key in defaults) {
        CFPreferencesSetAppValue((__bridge CFStringRef)key,
                                 (__bridge CFPropertyListRef)defaults[key],
                                 domain);
    }
    CFPreferencesAppSynchronize(domain);
    EdgeURLPrefsPostChanged();
    [self reloadSpecifiers];
}

#pragma mark - Typing a value

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self installValueEditorsInVisibleCells];
}

// A row is met as it comes on screen, when its number is already written on it.
// The framework's own work for the cell is done first and left as it was.
- (void)tableView:(UITableView *)tableView
    willDisplayCell:(UITableViewCell *)cell
 forRowAtIndexPath:(NSIndexPath *)indexPath {
    struct objc_super superInfo;
    superInfo.receiver = self;
    superInfo.super_class = class_getSuperclass([EdgeURLPrefsRootListController class]);
    SEL selector = _cmd;
    if (class_respondsToSelector(superInfo.super_class, selector)) {
        void (*sendSuper)(struct objc_super *, SEL, UITableView *, UITableViewCell *,
                          NSIndexPath *) =
            (void (*)(struct objc_super *, SEL, UITableView *, UITableViewCell *,
                      NSIndexPath *))objc_msgSendSuper;
        sendSuper(&superInfo, selector, tableView, cell, indexPath);
    }
    [self installValueEditorsOnCell:cell];
}

// Every row that shows a slider and a number gets a tap reader and a press
// reader on the row itself, so the number is easy to hit.
- (void)installValueEditorsInVisibleCells {
    UIView *root = self.view;
    if (![root isKindOfClass:[UITableView class]]) {
        return;
    }
    for (UITableViewCell *cell in ((UITableView *)root).visibleCells) {
        [self installValueEditorsOnCell:cell];
    }
}

- (void)installValueEditorsOnCell:(UITableViewCell *)cell {
    if (cell == nil || EdgeURLSliderInView(cell) == nil) {
        return;
    }
    BOOL hasTap = NO;
    BOOL hasPress = NO;
    for (UIGestureRecognizer *recognizer in cell.gestureRecognizers) {
        if ([recognizer isKindOfClass:[EdgeURLValueTapRecognizer class]]) {
            hasTap = YES;
        } else if ([recognizer isKindOfClass:[EdgeURLValuePressRecognizer class]]) {
            hasPress = YES;
        }
    }
    if (!hasTap) {
        EdgeURLValueTapRecognizer *tap =
            [[EdgeURLValueTapRecognizer alloc] initWithTarget:self action:@selector(valueTapped:)];
        // The slider keeps every touch it had: a tap is read and never taken.
        tap.cancelsTouchesInView = NO;
        tap.delaysTouchesEnded = NO;
        tap.delegate = self;
        [cell addGestureRecognizer:tap];
    }
    if (!hasPress) {
        EdgeURLValuePressRecognizer *press =
            [[EdgeURLValuePressRecognizer alloc] initWithTarget:self action:@selector(valuePressed:)];
        press.minimumPressDuration = 0.4;
        press.allowableMovement = 10.0;
        press.cancelsTouchesInView = NO;
        press.delaysTouchesEnded = NO;
        press.delegate = self;
        [cell addGestureRecognizer:press];
    }
}

// Only a touch that starts on the number is the reader's; the slider keeps the
// rest of the row to itself.
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    UIView *cell = recognizer.view;
    UILabel *label = EdgeURLNumberLabelInView(cell);
    if (label == nil) {
        // A row whose number could not be read still opens for a touch on its
        // right half, since that is where the number belongs.
        CGPoint point = [recognizer locationInView:cell];
        return point.x > cell.bounds.size.width * 0.5;
    }
    CGPoint point = [recognizer locationInView:label];
    BOOL inside =
        CGRectContainsPoint(CGRectInset(label.bounds, -20.0, -20.0), point);
    if (!inside) {
        // A short number such as 0.2 leaves very little to hit, so the whole
        // column the number sits in counts too.
        UIView *holder = label.superview;
        if (holder != nil) {
            CGPoint holderPoint = [recognizer locationInView:holder];
            inside = CGRectContainsPoint(holder.bounds, holderPoint);
        }
    }
    return inside;
}

static NSString *EdgeURLTrimmedText(NSString *text) {
    return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

// The number as the row shows it, minus a percentage sign: what the alert opens
// with, so typing replaces the value rather than adding to it.
static NSString *EdgeURLNumberTextInLabel(UILabel *label) {
    NSString *text = EdgeURLTrimmedText(label.text ?: @"");
    if ([text hasSuffix:@"%"]) {
        text = EdgeURLTrimmedText([text substringToIndex:text.length - 1]);
    }
    return text;
}

- (void)valueTapped:(UITapGestureRecognizer *)tap {
    if (tap.state != UIGestureRecognizerStateEnded) {
        return;
    }
    if ([tap.view isKindOfClass:[UITableViewCell class]]) {
        [self editValueInCell:(UITableViewCell *)tap.view];
    }
}

- (void)valuePressed:(UILongPressGestureRecognizer *)press {
    if (press.state != UIGestureRecognizerStateBegan) {
        return;
    }
    if ([press.view isKindOfClass:[UITableViewCell class]]) {
        [self editValueInCell:(UITableViewCell *)press.view];
    }
}

- (void)editValueInCell:(UITableViewCell *)cell {
    UILabel *label = EdgeURLNumberLabelInView(cell);
    UISlider *slider = EdgeURLSliderInView(cell);
    if (label == nil || slider == nil) {
        return;
    }
    [self editValueInLabel:label slider:slider cell:cell];
}

// The number opens a field to type it in, so a value far from where the knob
// sits takes one gesture rather than many.
- (void)editValueInLabel:(UILabel *)label
                  slider:(UISlider *)slider
                    cell:(UITableViewCell *)cell {
    BOOL percent = [(label.text ?: @"") hasSuffix:@"%"];
    NSString *typed = EdgeURLNumberTextInLabel(label);
    NSString *current = typed;
    PSSpecifier *specifier = nil;
    if (cell != nil && [cell respondsToSelector:@selector(specifier)]) {
        specifier = [cell specifier];
    }
    NSString *name = [specifier name] ?: @"Value";
    if (current.length == 0) {
        current = percent ? [NSString stringWithFormat:@"%g", slider.value * 100.0]
                          : [NSString stringWithFormat:@"%g", slider.value];
    }
    NSString *range = percent ? @"0 to 100 (%)"
                             : [NSString stringWithFormat:@"%g to %g",
                                    (double)slider.minimumValue, (double)slider.maximumValue];

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:name
                                            message:range
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = current;
        field.textAlignment = NSTextAlignmentCenter;
        field.keyboardType = UIKeyboardTypeDecimalPad;
    }];
    __weak UIAlertController *weakAlert = alert;
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Set"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action __unused) {
        [weakSelf setSlider:slider specifier:specifier percent:percent
                       text:weakAlert.textFields.firstObject.text];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

// The typed number, written where the row itself would write it.
- (void)setSlider:(UISlider *)slider
        specifier:(PSSpecifier *)specifier
          percent:(BOOL)percent
             text:(NSString *)typed {
    typed = EdgeURLTrimmedText(typed ?: @"");
    if ([typed hasSuffix:@"%"]) {
        typed = EdgeURLTrimmedText([typed substringToIndex:typed.length - 1]);
    }
    // A decimal pad types the locale's separator, which is a comma in much of the
    // world; the number itself is the same either way.
    typed = [typed stringByReplacingOccurrencesOfString:@"," withString:@"."];
    NSScanner *scanner = [NSScanner scannerWithString:typed];
    double number = 0.0;
    if (typed.length == 0 || ![scanner scanDouble:&number]) {
        return;
    }
    if (scanner.isAtEnd == NO) {
        NSString *rest = [typed substringFromIndex:scanner.scanLocation];
        if ([EdgeURLTrimmedText(rest) length] > 0) {
            return;  // Not a number: the value stays as it was.
        }
    }
    CGFloat min = slider.minimumValue;
    CGFloat max = slider.maximumValue;
    double value = percent ? (min + (number / 100.0) * (max - min)) : number;
    value = MIN(MAX(value, (double)min), (double)max);
    slider.value = (float)value;

    NSString *key = specifier != nil ? [specifier propertyForKey:@"key"] : nil;
    if (key.length > 0) {
        // Written where the row itself would write it, then the row is read back,
        // so the number shown and the tweak's copy are the same value.
        CFStringRef domain = (__bridge CFStringRef)EdgeURLPrefsDomain();
        CFPreferencesSetAppValue((__bridge CFStringRef)key,
                                 (__bridge CFPropertyListRef)@(value),
                                 domain);
        CFPreferencesAppSynchronize(domain);
        EdgeURLPrefsPostChanged();
        [self reloadSpecifier:specifier];
        return;
    }
    // No specifier to write through: the slider's own change is sent instead, as
    // dragging it would.
    [slider sendActionsForControlEvents:UIControlEventValueChanged];
}

@end
