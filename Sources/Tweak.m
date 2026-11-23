// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OwnGoal Studio
//
// The tweak's only entry point. The package's filter selects SpringBoard and
// nothing else: the trigger band belongs to the desktop, and no other process
// has a reason to load this dylib.
//
// The build defines APELIN_PACKAGE_ID, APELIN_VERSION and APELIN_BUILD_ID as
// string literals on every compile.
#import <UIKit/UIKit.h>
#import <os/log.h>
#import <substrate.h>

#import "EdgeURLGestureController.h"

static os_log_t TweakLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create(APELIN_PACKAGE_ID, "tweak");
    });
    return log;
}

static void (*OriginalDidFinishLaunching)(id self, SEL _cmd, id application);

// -[SpringBoard applicationDidFinishLaunching:] runs once per SpringBoard
// launch, after the constructor below has installed the hook. The scene is
// what the gesture controller needs, so it starts here and again when a scene
// connects.
static void HookedDidFinishLaunching(id self, SEL _cmd, id application) {
    if (OriginalDidFinishLaunching != NULL) {
        OriginalDidFinishLaunching(self, _cmd, application);
    }
    os_log(TweakLog(), "ApelinHooked %{public}s -[SpringBoard applicationDidFinishLaunching:]", APELIN_BUILD_ID);
    dispatch_async(dispatch_get_main_queue(), ^{
        [[EdgeURLGestureController sharedController] start];
    });
}

__attribute__((constructor)) static void TweakInitialize(void) {
    // Apelin's confirm_loaded looks for this exact marker and build id under
    // the package id's subsystem. Keep the line, and keep it public.
    os_log(TweakLog(), "ApelinLoaded %{public}s in %{public}s", APELIN_BUILD_ID, getprogname());

    Class springBoard = objc_getClass("SpringBoard");
    if (springBoard == Nil) {
        // The filter should never let this load anywhere else; if it somehow
        // does, there is nothing here to do.
        return;
    }
    MSHookMessageEx(springBoard,
                    @selector(applicationDidFinishLaunching:),
                    (IMP)HookedDidFinishLaunching,
                    (IMP *)&OriginalDidFinishLaunching);

    // The hook is not the only way in: in this springboard's launch the
    // delegate method is reached without passing through it, and then nothing
    // ever started. So the controller is started from here as well, once the
    // application has had time to bring its scene up. -start is idempotent.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        os_log(TweakLog(), "ApelinTimerStart %{public}s", APELIN_BUILD_ID);
        [[EdgeURLGestureController sharedController] start];
    });
}