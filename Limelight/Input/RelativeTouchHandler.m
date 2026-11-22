//
//  RelativeTouchHandler.m
//  Moonlight
//
//  Created by Cameron Gutman on 11/1/20.
//  Copyright © 2020 Moonlight Game Streaming Project. All rights reserved.
//

#import "RelativeTouchHandler.h"

#include <Limelight.h>

static const int REFERENCE_WIDTH = 1280;
static const int REFERENCE_HEIGHT = 720;

@implementation RelativeTouchHandler {
    CGPoint touchLocation, originalLocation;
    BOOL touchMoved;
    BOOL isDragging;
    NSTimer* dragTimer;
    NSUInteger peakTouchCount;
    
#if TARGET_OS_TV
    UIGestureRecognizer* remotePressRecognizer;
    UIGestureRecognizer* remoteLongPressRecognizer;
#endif
    
    __weak UIView* view;
#if !TARGET_OS_TV
    double fractionalX, fractionalY;
#endif
}

- (id)initWithView:(UIView*)view {
    self = [self init];
    self->view = view;
    
#if TARGET_OS_TV
    remotePressRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(remoteButtonPressed:)];
    remotePressRecognizer.allowedPressTypes = @[@(UIPressTypeSelect)];
    
    remoteLongPressRecognizer = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(remoteButtonLongPressed:)];
    remoteLongPressRecognizer.allowedPressTypes = @[@(UIPressTypeSelect)];
    
    [self->view addGestureRecognizer:remotePressRecognizer];
    [self->view addGestureRecognizer:remoteLongPressRecognizer];
#endif
    
    return self;
}

- (BOOL)isConfirmedMove:(CGPoint)currentPoint from:(CGPoint)originalPoint {
    // Movements of greater than 5 pixels are considered confirmed
    return hypotf(originalPoint.x - currentPoint.x, originalPoint.y - currentPoint.y) >= 5;
}

- (void)onDragStart:(NSTimer*)timer {
    if (!touchMoved && !isDragging){
        isDragging = true;
        LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT);
    }
}

#if TARGET_OS_TV
- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    touchMoved = false;
    peakTouchCount = [[event allTouches] count];
    if ([[event allTouches] count] == 1) {
        UITouch *touch = [[event allTouches] anyObject];
        originalLocation = touchLocation = [touch locationInView:view];
        if (!isDragging) {
            dragTimer = [NSTimer scheduledTimerWithTimeInterval:0.650
                                                     target:self
                                                   selector:@selector(onDragStart:)
                                                   userInfo:nil
                                                    repeats:NO];
        }
    }
    else if ([[event allTouches] count] == 2) {
        CGPoint firstLocation = [[[[event allTouches] allObjects] objectAtIndex:0] locationInView:view];
        CGPoint secondLocation = [[[[event allTouches] allObjects] objectAtIndex:1] locationInView:view];
        
        originalLocation = touchLocation = CGPointMake((firstLocation.x + secondLocation.x) / 2, (firstLocation.y + secondLocation.y) / 2);
    }
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    if ([[event allTouches] count] == 1) {
        UITouch *touch = [[event allTouches] anyObject];
        CGPoint currentLocation = [touch locationInView:view];
        
        if (touchLocation.x != currentLocation.x ||
            touchLocation.y != currentLocation.y)
        {
            int deltaX = (currentLocation.x - touchLocation.x) * (REFERENCE_WIDTH / view.bounds.size.width);
            int deltaY = (currentLocation.y - touchLocation.y) * (REFERENCE_HEIGHT / view.bounds.size.height);
            
            if (deltaX != 0 || deltaY != 0) {
                LiSendMouseMoveEvent(deltaX, deltaY);
                touchLocation = currentLocation;
                
                // If we've moved far enough to confirm this wasn't just human/machine error,
                // mark it as such.
                if ([self isConfirmedMove:touchLocation from:originalLocation]) {
                    touchMoved = true;
                }
            }
        }
    } else if ([[event allTouches] count] == 2) {
        CGPoint firstLocation = [[[[event allTouches] allObjects] objectAtIndex:0] locationInView:view];
        CGPoint secondLocation = [[[[event allTouches] allObjects] objectAtIndex:1] locationInView:view];
        
        CGPoint avgLocation = CGPointMake((firstLocation.x + secondLocation.x) / 2, (firstLocation.y + secondLocation.y) / 2);
        if (touchLocation.y != avgLocation.y) {
            LiSendHighResScrollEvent((avgLocation.y - touchLocation.y) * 10);
        }

        // If we've moved far enough to confirm this wasn't just human/machine error,
        // mark it as such.
        if ([self isConfirmedMove:firstLocation from:originalLocation]) {
            touchMoved = true;
        }
        
        touchLocation = avgLocation;
    }
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    [dragTimer invalidate];
    dragTimer = nil;
    if (isDragging) {
        isDragging = false;
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
    } else if (!touchMoved) {
        if (peakTouchCount == 2) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                Log(LOG_D, @"Sending right mouse button press");
                
                LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_RIGHT);
                
                // Wait 100 ms to simulate a real button press
                usleep(100 * 1000);
                
                LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_RIGHT);
            });
        } else if (peakTouchCount == 1) {
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                if (!self->isDragging){
                    Log(LOG_D, @"Sending left mouse button press");
                    
                    LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT);
                    
                    // Wait 100 ms to simulate a real button press
                    usleep(100 * 1000);
                }
                self->isDragging = false;
                LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
            });
        }
    }
    
    // We we're moving from 2+ touches to 1. Synchronize the current position
    // of the active finger so we don't jump unexpectedly on the next touchesMoved
    // callback when finger 1 switches on us.
    if ([[event allTouches] count] - [touches count] == 1) {
        NSMutableSet *activeSet = [[NSMutableSet alloc] initWithCapacity:[[event allTouches] count]];
        [activeSet unionSet:[event allTouches]];
        [activeSet minusSet:touches];
        touchLocation = [[activeSet anyObject] locationInView:view];
        
        // Mark this touch as moved so we don't send a left mouse click if the user
        // right clicks without moving their other finger.
        touchMoved = true;
    }
}

#else
- (CGPoint)centerOfTouches:(NSSet<UITouch *> *)touches {
    CGPoint center = CGPointZero;
    for (UITouch *touch in touches) {
        CGPoint point = [touch locationInView:view];
        center.x += point.x;
        center.y += point.y;
    }
    return CGPointMake(center.x / touches.count, center.y / touches.count);
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    NSSet<UITouch *> *active = [event touchesForView:view];
    if (active.count == 1) {
        [self cancelTouches];
        peakTouchCount = 1;
        originalLocation = touchLocation = [touches.anyObject locationInView:view];
        fractionalX = fractionalY = 0;
        dragTimer = [NSTimer scheduledTimerWithTimeInterval:0.45 target:self selector:@selector(onDragStart:)
                                                   userInfo:nil repeats:NO];
    } else if (active.count > 1) {
        BOOL moved = touchMoved || isDragging;
        NSUInteger peak = MAX(active.count, peakTouchCount);
        [self cancelTouches];
        peakTouchCount = peak;
        touchMoved = moved;
        originalLocation = touchLocation = [self centerOfTouches:active];
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    NSSet<UITouch *> *active = [event touchesForView:view];
    if (active.count == 0 || active.count != peakTouchCount || active.count > 2) { return; }
    CGPoint current = [self centerOfTouches:active];
    CGFloat dx = current.x - touchLocation.x;
    CGFloat dy = current.y - touchLocation.y;
    if ([self isConfirmedMove:current from:originalLocation]) {
        touchMoved = YES;
        [dragTimer invalidate];
        dragTimer = nil;
    }
    if (active.count == 1) {
        double gain = 1280.0 / MAX(320.0, CGRectGetWidth(view.bounds));
        fractionalX += dx * gain;
        fractionalY += dy * gain;
        short moveX = (short)trunc(fractionalX);
        short moveY = (short)trunc(fractionalY);
        if (moveX || moveY) { LiSendMouseMoveEvent(moveX, moveY); }
        fractionalX -= moveX;
        fractionalY -= moveY;
    } else if (touchMoved) {
        short vertical = (short)lround(dy * 10);
        short horizontal = (short)lround(-dx * 10);
        if (vertical) { LiSendHighResScrollEvent(vertical); }
        if (horizontal) { LiSendHighResHScrollEvent(horizontal); }
    }
    touchLocation = current;
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if ([event touchesForView:view].count > touches.count) { return; }
    if (!touchMoved && !isDragging && (peakTouchCount == 1 || peakTouchCount == 2)) {
        int button = peakTouchCount == 2 ? BUTTON_RIGHT : BUTTON_LEFT;
        LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, button);
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, button);
    }
    [self cancelTouches];
}
#endif

- (void)cancelTouches {
    [dragTimer invalidate];
    dragTimer = nil;
    if (isDragging) {
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
    }
    isDragging = NO;
    touchMoved = NO;
    peakTouchCount = 0;
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self cancelTouches];
}

#if TARGET_OS_TV
- (void)remoteButtonPressed:(id)sender {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        Log(LOG_D, @"Sending left mouse button press");
        
        // Mark this as touchMoved to avoid a duplicate press on touch up
        self->touchMoved = true;
        
        LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT);
        
        // Wait 100 ms to simulate a real button press
        usleep(100 * 1000);
            
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
    });
}
- (void)remoteButtonLongPressed:(id)sender {
    Log(LOG_D, @"Holding left mouse button");
    
    isDragging = true;
    LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT);
}
#endif

@end
