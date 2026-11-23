//
//  StreamView.h
//  Moonlight
//
//  Created by Cameron Gutman on 10/19/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "ControllerSupport.h"
#import "OnScreenControls.h"
#import "Moonlight-Swift.h"
#import "StreamConfiguration.h"

@protocol UserInteractionDelegate <NSObject>

- (void) userInteractionBegan;
- (void) userInteractionEnded;

@end

#if TARGET_OS_TV
@interface StreamView : UIView <X1KitMouseDelegate, UITextFieldDelegate>
#else
@interface StreamView : UIView <X1KitMouseDelegate, UITextFieldDelegate, UIPointerInteractionDelegate>
#endif

- (void) setupStreamView:(ControllerSupport*)controllerSupport
     interactionDelegate:(id<UserInteractionDelegate>)interactionDelegate
                  config:(StreamConfiguration*)streamConfig;
- (void) showOnScreenControls;
- (OnScreenControlsLevel) getCurrentOscState;
- (CGRect)videoContentRect;
- (void)setStreamWidth:(int)width height:(int)height;

#if !TARGET_OS_TV
- (void) updateCursorLocation:(CGPoint)location isMouse:(BOOL)isMouse;
- (void)setFillVideo:(BOOL)fill;
- (void)setCaptureAspect:(double)aspect;
- (CGRect)visibleDesktopRect;
- (void)setDirectTouch:(BOOL)direct;
- (void)toggleSoftwareKeyboard;
- (BOOL)toggleDesktopModifier:(short)keyCode;
- (BOOL)isDesktopModifierHeld:(short)keyCode;
- (void)sendDesktopShortcut:(NSArray<NSNumber *> *)keys;
- (BOOL)sendDesktopText:(NSString *)text;
- (void)releaseDesktopInput;
#endif

@end
