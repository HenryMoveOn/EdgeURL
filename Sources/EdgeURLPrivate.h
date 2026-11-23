// SPDX-License-Identifier: MIT
//
// Nothing here any more. The tweak used to hand its recognizer to the window
// scene's system gesture manager, which the SDK does not declare; SpringBoard
// refuses recognizers put in a slot it has taken, and the refusal ended the
// process. Touches are now taken from SpringBoard's own windows, which needs
// no private API at all.
#import <UIKit/UIKit.h>