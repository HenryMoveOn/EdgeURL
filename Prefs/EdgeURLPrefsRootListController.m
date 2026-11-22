// SPDX-License-Identifier: MIT
//
// The settings pane. PSListController reads and writes the rows of Root.plist
// and Area.plist in the local.apelin.edgeurl domain, and each row posts
// local.apelin.edgeurl/changed, which is what the tweak listens for.
#import <Preferences/PSListController.h>
#import <UIKit/UIKit.h>
#import <notify.h>

@interface EdgeURLPrefsRootListController : PSListController
@end

@interface EdgeURLPrefsAreaListController : PSListController
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
        @"ShowArea" : @YES,
        @"AreaAlpha" : @0.2,
    };
}

static void EdgeURLPrefsPostChanged(void) {
    notify_post(APELIN_PACKAGE_ID "/changed");
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

@end

@implementation EdgeURLPrefsAreaListController

- (NSArray *)specifiers {
    if (_specifiers == nil) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Area" target:self];
    }
    return _specifiers;
}

@end
