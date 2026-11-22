//
//  AbsoluteTouchHandler.m
//  Moonlight
//
//  Created by Cameron Gutman on 11/1/20.
//  Copyright © 2020 Moonlight Game Streaming Project. All rights reserved.
//

#import "AbsoluteTouchHandler.h"

#include <Limelight.h>

@implementation AbsoluteTouchHandler {
    __weak StreamView *_view;
    UITouch *_primaryTouch;
    NSTimer *_rightClickTimer;
    CGPoint _start;
    CGPoint _clickLocation;
    CGPoint _lastTap;
    NSTimeInterval _lastTapEnd;
    CGPoint _scrollCenter;
    BOOL _dragging;
    BOOL _rightClicked;
    BOOL _multipleTouches;
}

- (instancetype)initWithView:(StreamView *)view {
    if ((self = [super init])) {
        _view = view;
    }
    return self;
}

- (void)cancelTimer {
    [_rightClickTimer invalidate];
    _rightClickTimer = nil;
}

- (void)cancelTouches {
    [self cancelTimer];
    if (_dragging) {
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
    }
    _dragging = NO;
    _primaryTouch = nil;
    _rightClicked = NO;
    _multipleTouches = NO;
}

- (CGPoint)centerOfTouches:(NSSet<UITouch *> *)touches {
    CGPoint center = CGPointZero;
    for (UITouch *touch in touches) {
        CGPoint point = [touch locationInView:_view];
        center.x += point.x;
        center.y += point.y;
    }
    return CGPointMake(center.x / touches.count, center.y / touches.count);
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    NSSet<UITouch *> *active = [event touchesForView:_view];
    if (active.count > 1) {
        [self cancelTouches];
        _multipleTouches = YES;
        if (active.count == 2) {
            _scrollCenter = [self centerOfTouches:active];
        }
        return;
    }
    UITouch *touch = touches.anyObject;
    CGPoint point = [touch locationInView:_view];
    if (!CGRectContainsPoint([_view videoContentRect], point)) {
        return;
    }
    _primaryTouch = touch;
    _start = point;
    if (_lastTapEnd > 0 && touch.timestamp - _lastTapEnd < 0.28 &&
        hypot(point.x - _lastTap.x, point.y - _lastTap.y) <= 10) {
        point = _lastTap;
    }
    _clickLocation = point;
    [_view updateCursorLocation:point isMouse:NO];
    _rightClickTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(rightClick:)
                                                     userInfo:nil repeats:NO];
}

- (void)rightClick:(NSTimer *)timer {
    _rightClickTimer = nil;
    if (_primaryTouch && !_dragging) {
        LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_RIGHT);
        LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_RIGHT);
        _rightClicked = YES;
        _lastTapEnd = 0;
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    NSSet<UITouch *> *active = [event touchesForView:_view];
    if (_multipleTouches && active.count == 2) {
        CGPoint center = [self centerOfTouches:active];
        short vertical = (short)lround((center.y - _scrollCenter.y) * 10);
        short horizontal = (short)lround((_scrollCenter.x - center.x) * 10);
        if (vertical) { LiSendHighResScrollEvent(vertical); }
        if (horizontal) { LiSendHighResHScrollEvent(horizontal); }
        _scrollCenter = center;
        return;
    }
    if (_rightClicked || !_primaryTouch || ![touches containsObject:_primaryTouch]) {
        return;
    }
    CGPoint point = [_primaryTouch locationInView:_view];
    if (!_dragging && hypot(point.x - _start.x, point.y - _start.y) >= 4) {
        [self cancelTimer];
        LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT);
        _dragging = YES;
        _lastTapEnd = 0;
    }
    if (_dragging) {
        [_view updateCursorLocation:point isMouse:NO];
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_multipleTouches) {
        if ([event touchesForView:_view].count <= touches.count) { [self cancelTouches]; }
        return;
    }
    if (_primaryTouch && [touches containsObject:_primaryTouch]) {
        if (!_dragging && !_rightClicked) {
            LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT);
            LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
            _lastTapEnd = _primaryTouch.timestamp;
            _lastTap = _clickLocation;
        }
        [self cancelTouches];
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self cancelTouches];
}

@end
