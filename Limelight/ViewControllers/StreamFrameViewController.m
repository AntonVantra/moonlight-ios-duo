//
//  StreamFrameViewController.m
//  Moonlight
//
//  Created by Diego Waxemberg on 1/18/14.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "StreamFrameViewController.h"
#import "MainFrameViewController.h"
#import "VideoDecoderRenderer.h"
#import "StreamManager.h"
#import "ControllerSupport.h"
#import "DataManager.h"
#import "DesktopGeometry.h"
#if !TARGET_OS_TV
#import "RelativeTouchHandler.h"
#endif

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <Limelight.h>

#if TARGET_OS_TV
#import <AVFoundation/AVDisplayCriteria.h>
#import <AVKit/AVDisplayManager.h>
#import <AVKit/UIWindow.h>
#endif

@interface AVDisplayCriteria()
@property(readonly) int videoDynamicRange;
@property(readonly, nonatomic) float refreshRate;
- (id)initWithRefreshRate:(float)arg1 videoDynamicRange:(int)arg2;
@end

#if !TARGET_OS_TV
typedef NS_ENUM(NSInteger, DesktopLayout) {
    DesktopLayoutAutomatic,
    DesktopLayoutFullScreen,
    DesktopLayoutLaptop,
};

@interface DesktopTrackpadView : UIView
- (void)releasePointer;
@end

@implementation DesktopTrackpadView {
    RelativeTouchHandler *_touchHandler;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.multipleTouchEnabled = YES;
        self.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1];
        self.accessibilityLabel = @"Windows trackpad";
        _touchHandler = [[RelativeTouchHandler alloc] initWithView:self];
    }
    return self;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [_touchHandler touchesBegan:touches withEvent:event];
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [_touchHandler touchesMoved:touches withEvent:event];
}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [_touchHandler touchesEnded:touches withEvent:event];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    [self releasePointer];
}
- (void)releasePointer {
    [_touchHandler cancelTouches];
}
@end

static DesktopRect DesktopRectFromCGRect(CGRect rect) {
    return (DesktopRect){rect.origin.x, rect.origin.y, rect.size.width, rect.size.height};
}

static CGRect DesktopCGRect(DesktopRect rect) {
    return CGRectMake(rect.x, rect.y, rect.width, rect.height);
}
#endif

@implementation StreamFrameViewController {
    ControllerSupport *_controllerSupport;
    StreamManager *_streamMan;
    TemporarySettings *_settings;
    NSTimer *_inactivityTimer;
    NSTimer *_statsUpdateTimer;
    UITapGestureRecognizer *_menuTapGestureRecognizer;
    UITapGestureRecognizer *_menuDoubleTapGestureRecognizer;
    UITapGestureRecognizer *_playPauseTapGestureRecognizer;
    UITextView *_overlayView;
    UILabel *_stageLabel;
    UILabel *_tipLabel;
    UIActivityIndicatorView *_spinner;
    StreamView *_streamView;
    CGRect _lastVideoFrame;
    BOOL _leaving;
#if !TARGET_OS_TV
    DesktopPoseObserver *_desktopPose;
    CGRect _desktopNegotiationFrame;
    NSString *_deferredDesktopConnectionError;
    DesktopTrackpadView *_desktopTrackpad;
    UIButton *_desktopMenuButton;
    DesktopLayout _desktopLayout;
    BOOL _desktopDirectTouch;
    BOOL _desktopFill;
    NSInteger _desktopCaptureChoice;
    BOOL _adaptiveDesktop;
    BOOL _desktopReady;
    BOOL _restartingDesktop;
    NSInteger _automaticRetries;
    int _fixedWidth, _fixedHeight, _requestedFPS;
    NSTimer *_desktopResizeTimer;
#endif
    UIScrollView *_scrollView;
    BOOL _userIsInteracting;
    
#if !TARGET_OS_TV
    UIScreenEdgePanGestureRecognizer *_exitSwipeRecognizer;
#endif
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    
#if !TARGET_OS_TV
    [[self revealViewController] setPrimaryViewController:self];
    if (_deferredDesktopConnectionError) {
        NSString *message = _deferredDesktopConnectionError;
        _deferredDesktopConnectionError = nil;
        if (!_desktopReady && !_leaving) {
            [self showDesktopConnectionError:message];
        }
    }
    if (_desktopReady && !self.presentedViewController) {
        [_streamView becomeFirstResponder];
    }
#endif
    if (!_streamMan && !_leaving) {
        [self beginStream];
    }
}

#if TARGET_OS_TV
- (void)controllerPauseButtonPressed:(id)sender { }
- (void)controllerPauseButtonDoublePressed:(id)sender {
    Log(LOG_I, @"Menu double-pressed -- backing out of stream");
    [self returnToMainFrame];
}
- (void)controllerPlayPauseButtonPressed:(id)sender {
    Log(LOG_I, @"Play/Pause button pressed -- backing out of stream");
    [self returnToMainFrame];
}
#endif


- (void)viewDidLoad
{
    [super viewDidLoad];
    
    [self.navigationController setNavigationBarHidden:YES animated:YES];
    
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    
    _settings = [[[DataManager alloc] init] getSettings];
#if !TARGET_OS_TV
    _fixedWidth = self.streamConfig.width;
    _fixedHeight = self.streamConfig.height;
    _requestedFPS = self.streamConfig.frameRate;
    _desktopDirectTouch = _settings.absoluteTouchMode;
    _adaptiveDesktop = ![[NSUserDefaults standardUserDefaults] boolForKey:@"DesktopUseFixedResolution"];
    _automaticRetries = 1;
#endif
    
    _stageLabel = [[UILabel alloc] init];
    [_stageLabel setUserInteractionEnabled:NO];
    [_stageLabel setText:[NSString stringWithFormat:@"Starting %@...", self.streamConfig.appName]];
    [_stageLabel sizeToFit];
    _stageLabel.textAlignment = NSTextAlignmentCenter;
    _stageLabel.textColor = [UIColor whiteColor];
    _stageLabel.center = CGPointMake(self.view.frame.size.width / 2, self.view.frame.size.height / 2);
    
    _spinner = [[UIActivityIndicatorView alloc] init];
    [_spinner setUserInteractionEnabled:NO];
#if TARGET_OS_TV
    [_spinner setActivityIndicatorViewStyle:UIActivityIndicatorViewStyleWhiteLarge];
#else
    [_spinner setActivityIndicatorViewStyle:UIActivityIndicatorViewStyleWhite];
#endif
    [_spinner sizeToFit];
    [_spinner startAnimating];
    _spinner.center = CGPointMake(self.view.frame.size.width / 2, self.view.frame.size.height / 2 - _stageLabel.frame.size.height - _spinner.frame.size.height);
    
    _controllerSupport = [[ControllerSupport alloc] initWithConfig:self.streamConfig delegate:self];
    _inactivityTimer = nil;
    
    _streamView = [[StreamView alloc] initWithFrame:self.view.bounds];
    _streamView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_streamView setupStreamView:_controllerSupport interactionDelegate:self config:self.streamConfig];
    
#if TARGET_OS_TV
    if (!_menuTapGestureRecognizer || !_menuDoubleTapGestureRecognizer || !_playPauseTapGestureRecognizer) {
        _menuTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(controllerPauseButtonPressed:)];
        _menuTapGestureRecognizer.allowedPressTypes = @[@(UIPressTypeMenu)];

        _playPauseTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(controllerPlayPauseButtonPressed:)];
        _playPauseTapGestureRecognizer.allowedPressTypes = @[@(UIPressTypePlayPause)];
        
        _menuDoubleTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(controllerPauseButtonDoublePressed:)];
        _menuDoubleTapGestureRecognizer.numberOfTapsRequired = 2;
        [_menuTapGestureRecognizer requireGestureRecognizerToFail:_menuDoubleTapGestureRecognizer];
        _menuDoubleTapGestureRecognizer.allowedPressTypes = @[@(UIPressTypeMenu)];
    }
    
    [self.view addGestureRecognizer:_menuTapGestureRecognizer];
    [self.view addGestureRecognizer:_menuDoubleTapGestureRecognizer];
    [self.view addGestureRecognizer:_playPauseTapGestureRecognizer];

#else
    _exitSwipeRecognizer = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(edgeSwiped)];
    _exitSwipeRecognizer.edges = UIRectEdgeLeft;
    _exitSwipeRecognizer.delaysTouchesBegan = NO;
    _exitSwipeRecognizer.delaysTouchesEnded = NO;
    
    [self.view addGestureRecognizer:_exitSwipeRecognizer];
#endif
    
    _tipLabel = [[UILabel alloc] init];
    [_tipLabel setUserInteractionEnabled:NO];
    
#if TARGET_OS_TV
    [_tipLabel setText:@"Tip: Tap the Play/Pause button on the Apple TV Remote to disconnect from your PC"];
#else
    [_tipLabel setText:@"Tip: Swipe from the left edge to disconnect from your PC"];
#endif
    
    [_tipLabel sizeToFit];
    _tipLabel.textColor = [UIColor whiteColor];
    _tipLabel.textAlignment = NSTextAlignmentCenter;
    _tipLabel.center = CGPointMake(self.view.frame.size.width / 2, self.view.frame.size.height * 0.9);
    
    NSNotificationCenter *notifications = [NSNotificationCenter defaultCenter];
#if TARGET_OS_TV
    [notifications addObserver:self selector:@selector(applicationWillResignActive:) name:UIApplicationWillResignActiveNotification object:nil];
    [notifications addObserver:self selector:@selector(applicationDidBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [notifications addObserver:self selector:@selector(applicationDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
#else
    [notifications addObserver:self selector:@selector(applicationWillResignActive:) name:UISceneWillDeactivateNotification object:nil];
    [notifications addObserver:self selector:@selector(applicationDidBecomeActive:) name:UISceneDidActivateNotification object:nil];
    [notifications addObserver:self selector:@selector(applicationDidEnterBackground:) name:UISceneDidEnterBackgroundNotification object:nil];
#endif

    // Desktop also allows local pinch-to-zoom while in trackpad mode.
    if (_settings.absoluteTouchMode || self.streamConfig.desktopMode) {
        _scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
        _scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
#if !TARGET_OS_TV
        [_scrollView.panGestureRecognizer setMinimumNumberOfTouches:2];
#endif
        [_scrollView setShowsHorizontalScrollIndicator:NO];
        [_scrollView setShowsVerticalScrollIndicator:NO];
        [_scrollView setDelegate:self];
        [_scrollView setMaximumZoomScale:self.streamConfig.desktopMode ? 4.0 : 10.0];
#if !TARGET_OS_TV
        if (self.streamConfig.desktopMode) {
            _scrollView.autoresizingMask = UIViewAutoresizingNone;
            _streamView.autoresizingMask = UIViewAutoresizingNone;
            _scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
            _scrollView.delaysContentTouches = NO;
            _scrollView.panGestureRecognizer.enabled = NO;
        }
#endif
        
        // Add StreamView inside a UIScrollView for absolute mode
        [_scrollView addSubview:_streamView];
        [self.view addSubview:_scrollView];
    }
    else {
        // Add StreamView directly in relative mode
        [self.view addSubview:_streamView];
    }
    
    [self.view addSubview:_stageLabel];
    [self.view addSubview:_spinner];
    [self.view addSubview:_tipLabel];
#if !TARGET_OS_TV
    if (self.streamConfig.desktopMode) {
        [self installDesktopControls];
    }
#endif
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    return _streamView;
}

- (void)scrollViewDidZoom:(UIScrollView *)scrollView {
#if !TARGET_OS_TV
    if (self.streamConfig.desktopMode) {
        scrollView.panGestureRecognizer.enabled = scrollView.zoomScale > 1.001;
    }
#endif
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];

    CGRect bounds = self.view.bounds;
    CGRect videoFrame = bounds;
#if !TARGET_OS_TV
    BOOL negotiationFrameChanged = NO;
    if (_desktopTrackpad) {
        BOOL laptop = _desktopLayout == DesktopLayoutLaptop ||
                      (_desktopLayout == DesktopLayoutAutomatic && _desktopPose.isLaptopPose);
        DesktopPanes panes = DesktopLaptopPanes(DesktopRectFromCGRect(bounds),
                                                DesktopRectFromCGRect(_desktopPose.horizontalDivision),
                                                laptop);
        CGRect trackpadFrame = DesktopCGRect(panes.trackpad);
        if (!CGRectEqualToRect(trackpadFrame, _desktopTrackpad.frame)) {
            [_desktopTrackpad releasePointer];
            _desktopTrackpad.frame = trackpadFrame;
        }
        _desktopTrackpad.hidden = CGRectIsEmpty(trackpadFrame);
        videoFrame = DesktopCGRect(panes.video);
        negotiationFrameChanged = !CGRectEqualToRect(_desktopNegotiationFrame, videoFrame);
        _desktopNegotiationFrame = videoFrame;

        // The local keyboard changes presentation without renegotiating the stream.
        CGFloat keyboardTop = CGRectGetMinY(self.view.keyboardLayoutGuide.layoutFrame);
        CGFloat safeAreaBottom = CGRectGetMaxY(self.view.safeAreaLayoutGuide.layoutFrame);
        videoFrame = DesktopCGRect(DesktopVideoAboveKeyboard(panes.video, keyboardTop, safeAreaBottom));
    }
    if (negotiationFrameChanged) {
        [self scheduleDesktopResolutionUpdate];
    }
#endif
    if (CGRectEqualToRect(videoFrame, _lastVideoFrame)) {
        return;
    }
    _lastVideoFrame = videoFrame;

    if (_scrollView) {
#if !TARGET_OS_TV
        CGFloat previousZoom = self.streamConfig.desktopMode ? _scrollView.zoomScale : 1;
        DesktopPoint center = {0.5, 0.5};
        if (previousZoom > 1) {
            CGPoint focalPoint = [self desktopViewportCenter];
            center = DesktopMapPoint(DesktopRectFromCGRect([_streamView videoContentRect]), focalPoint.x, focalPoint.y);
        }
#endif
        [_scrollView setZoomScale:1 animated:NO];
        _scrollView.frame = videoFrame;
        _scrollView.contentOffset = CGPointZero;
        _streamView.frame = (CGRect){CGPointZero, videoFrame.size};
        _scrollView.contentSize = videoFrame.size;
#if !TARGET_OS_TV
        if (previousZoom > 1) {
            [_scrollView setZoomScale:previousZoom animated:NO];
            CGRect encoded = [_streamView videoContentRect];
            CGPoint focus = CGPointMake(CGRectGetMinX(encoded) + center.x * CGRectGetWidth(encoded),
                                        CGRectGetMinY(encoded) + center.y * CGRectGetHeight(encoded));
            CGPoint contentPoint = [_scrollView convertPoint:focus fromView:_streamView];
            DesktopPoint offset = DesktopCenteredScrollOffset(
                (DesktopPoint){contentPoint.x, contentPoint.y}, DesktopRectFromCGRect(_scrollView.bounds),
                _scrollView.contentSize.width, _scrollView.contentSize.height);
            _scrollView.contentOffset = CGPointMake(offset.x, offset.y);
        }
#endif
    } else {
        _streamView.frame = videoFrame;
    }

    _stageLabel.center = CGPointMake(CGRectGetMidX(videoFrame), CGRectGetMidY(videoFrame));
    _spinner.center = CGPointMake(CGRectGetMidX(videoFrame), CGRectGetMidY(videoFrame) - 36);
    _tipLabel.center = CGPointMake(CGRectGetMidX(videoFrame), CGRectGetMaxY(videoFrame) - 36);
    [_streamMan updateRendererLayout];
}

- (void)beginStream {
#if !TARGET_OS_TV
    if (self.streamConfig.desktopMode) {
        DesktopPixels size = [self desktopStreamPixels];
        self.streamConfig.width = size.width;
        self.streamConfig.height = size.height;
        NSInteger maxFPS = self.view.window.windowScene.screen.maximumFramesPerSecond;
        self.streamConfig.frameRate = maxFPS > 0 ? MIN(_requestedFPS, (int)maxFPS) : _requestedFPS;
        [_streamView setStreamWidth:size.width height:size.height];
    }
#endif
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    _streamMan = [[StreamManager alloc] initWithConfig:self.streamConfig renderView:_streamView connectionCallbacks:self];
    NSOperationQueue *queue = [[NSOperationQueue alloc] init];
    [queue addOperation:_streamMan];
}

#if !TARGET_OS_TV
- (DesktopPixels)desktopStreamPixels {
    if (_adaptiveDesktop) {
        CGFloat scale = self.view.window.windowScene.screen.nativeScale;
        DesktopPixels pixels = DesktopAdaptivePixels(DesktopRectFromCGRect(_desktopNegotiationFrame), scale, 3840);
        if (pixels.width > 0 && pixels.height > 0) { return pixels; }
    }
    return (DesktopPixels){_fixedWidth, _fixedHeight};
}

- (void)scheduleDesktopResolutionUpdate {
    [_desktopResizeTimer invalidate];
    _desktopResizeTimer = nil;
    if (!_desktopReady || !_adaptiveDesktop || _restartingDesktop || _leaving) {
        return;
    }
    if (!DesktopResolutionChanged(self.streamConfig.width, self.streamConfig.height, [self desktopStreamPixels])) {
        return;
    }
    _desktopResizeTimer = [NSTimer scheduledTimerWithTimeInterval:1.15 target:self
                                                       selector:@selector(applyDesktopResize:)
                                                       userInfo:nil repeats:NO];
}

- (void)applyDesktopResize:(NSTimer *)timer {
    _desktopResizeTimer = nil;
    if (_desktopReady && !_userIsInteracting &&
        self.view.window.windowScene.activationState == UISceneActivationStateForegroundActive) {
        [self restartDesktopStream:@"Matching display size"];
    }
}

- (void)restartDesktopStream:(NSString *)status {
    if (_restartingDesktop || _leaving) { return; }
    _restartingDesktop = YES;
    _desktopReady = NO;
    _deferredDesktopConnectionError = nil;
    [_desktopResizeTimer invalidate];
    _desktopResizeTimer = nil;
    [_statsUpdateTimer invalidate];
    _statsUpdateTimer = nil;
    _overlayView.hidden = YES;
    [_streamView releaseDesktopInput];
    [_desktopTrackpad releasePointer];
    _streamView.userInteractionEnabled = NO;
    _desktopTrackpad.userInteractionEnabled = NO;
    _stageLabel.text = status;
    [_stageLabel sizeToFit];
    _stageLabel.center = CGPointMake(CGRectGetMidX(_lastVideoFrame), CGRectGetMidY(_lastVideoFrame));
    _stageLabel.hidden = NO;
    [_spinner startAnimating];

    [_streamMan stopStreamWithCompletion:^{
        if (self->_leaving) { return; }
        self->_restartingDesktop = NO;
        [self beginStream];
    }];
}

- (void)installDesktopControls {
    __weak StreamFrameViewController *weakSelf = self;
    _desktopPose = [[DesktopPoseObserver alloc] initWithView:self.view onChange:^{
        [weakSelf.view setNeedsLayout];
    }];
    _desktopTrackpad = [[DesktopTrackpadView alloc] initWithFrame:CGRectZero];
    _desktopTrackpad.hidden = YES;
    _desktopTrackpad.userInteractionEnabled = NO;
    [self.view insertSubview:_desktopTrackpad belowSubview:_stageLabel];
    _streamView.userInteractionEnabled = NO;

    UIButtonConfiguration *keyboardStyle = [UIButtonConfiguration grayButtonConfiguration];
    keyboardStyle.image = [UIImage systemImageNamed:@"keyboard"];
    UIButton *keyboard = [UIButton buttonWithConfiguration:keyboardStyle primaryAction:
        [UIAction actionWithHandler:^(UIAction *action) {
            StreamFrameViewController *controller = weakSelf;
            if (controller && controller->_desktopReady) {
                [controller->_streamView toggleSoftwareKeyboard];
            }
        }]];
    keyboard.accessibilityLabel = @"Windows keyboard";

    UIButtonConfiguration *menuStyle = [UIButtonConfiguration grayButtonConfiguration];
    menuStyle.image = [UIImage systemImageNamed:@"ellipsis.circle"];
    _desktopMenuButton = [UIButton buttonWithConfiguration:menuStyle primaryAction:nil];
    _desktopMenuButton.accessibilityLabel = @"Desktop controls";
    _desktopMenuButton.showsMenuAsPrimaryAction = YES;
    [self updateDesktopMenu];

    UIStackView *controls = [[UIStackView alloc] initWithArrangedSubviews:@[keyboard, _desktopMenuButton]];
    controls.translatesAutoresizingMaskIntoConstraints = NO;
    controls.spacing = 4;
    [self.view addSubview:controls];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    NSLayoutConstraint *aboveKeyboard = [controls.bottomAnchor
        constraintLessThanOrEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor constant:-4];
    aboveKeyboard.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        aboveKeyboard,
        [controls.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8],
        [controls.topAnchor constraintEqualToAnchor:safe.topAnchor constant:8],
        [keyboard.widthAnchor constraintGreaterThanOrEqualToConstant:44],
        [keyboard.heightAnchor constraintGreaterThanOrEqualToConstant:44],
        [_desktopMenuButton.widthAnchor constraintGreaterThanOrEqualToConstant:44],
    ]];
}

- (CGPoint)desktopViewportCenter {
    CGPoint center = CGPointMake(CGRectGetMidX(_scrollView.bounds), CGRectGetMidY(_scrollView.bounds));
    return [_streamView convertPoint:center fromView:_scrollView];
}

- (void)zoomDesktopBy:(CGFloat)factor {
    CGSize viewport = _scrollView.bounds.size;
    if (viewport.width <= 0 || viewport.height <= 0) { return; }
    CGFloat zoom = MIN(_scrollView.maximumZoomScale, MAX(_scrollView.minimumZoomScale, _scrollView.zoomScale * factor));
    if (zoom == _scrollView.minimumZoomScale) {
        [_scrollView setZoomScale:zoom animated:YES];
        return;
    }
    CGPoint center = [self desktopViewportCenter];
    CGFloat width = viewport.width / zoom;
    CGFloat height = viewport.height / zoom;
    [_scrollView zoomToRect:CGRectMake(center.x - width / 2, center.y - height / 2, width, height) animated:YES];
}

- (void)showDesktopTextComposer {
    if (!_desktopReady || self.presentedViewController) { return; }
    [_streamView releaseDesktopInput];
    [_desktopTrackpad releasePointer];
    [self updateDesktopMenu];
    __weak StreamFrameViewController *weakSelf = self;
    DesktopTextComposer *composer = [[DesktopTextComposer alloc] initWithSendText:^BOOL(NSString *text) {
        StreamFrameViewController *controller = weakSelf;
        return controller && controller->_desktopReady && [controller->_streamView sendDesktopText:text];
    }];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:composer];
    navigation.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:navigation animated:YES completion:nil];
}

- (NSArray<UIAction *> *)desktopShortcutActions:(NSArray<NSString *> *)titles
                                          keys:(NSDictionary<NSString *, NSArray<NSNumber *> *> *)shortcuts {
    __weak StreamFrameViewController *weakSelf = self;
    NSMutableArray<UIAction *> *actions = [NSMutableArray arrayWithCapacity:titles.count];
    for (NSString *title in titles) {
        NSArray<NSNumber *> *chord = shortcuts[title];
        [actions addObject:[UIAction actionWithTitle:title image:nil identifier:nil handler:^(UIAction *action) {
            StreamFrameViewController *controller = weakSelf;
            if (controller && controller->_desktopReady) {
                [controller->_streamView sendDesktopShortcut:chord];
            }
        }]];
    }
    return actions;
}

- (void)updateDesktopMenu {
    __weak StreamFrameViewController *weakSelf = self;
    NSMutableArray<UIAction *> *layouts = [NSMutableArray array];
    NSArray<NSString *> *layoutNames = @[@"Automatic", @"Full screen", @"Laptop"];
    for (NSInteger i = 0; i < (NSInteger)layoutNames.count; i++) {
        UIAction *choice = [UIAction actionWithTitle:layoutNames[i] image:nil identifier:nil handler:^(UIAction *action) {
            StreamFrameViewController *controller = weakSelf;
            if (!controller) { return; }
            controller->_desktopLayout = (DesktopLayout)i;
            [controller.view setNeedsLayout];
            [controller updateDesktopMenu];
        }];
        choice.state = _desktopLayout == i ? UIMenuElementStateOn : UIMenuElementStateOff;
        [layouts addObject:choice];
    }

    NSMutableArray<UIAction *> *modifiers = [NSMutableArray array];
    NSArray<NSString *> *names = @[@"Ctrl", @"Alt", @"Shift", @"Windows"];
    NSArray<NSNumber *> *keys = @[@0xa2, @0xa4, @0xa0, @0x5b];
    for (NSUInteger i = 0; i < names.count; i++) {
        short keyCode = keys[i].shortValue;
        UIAction *modifier = [UIAction actionWithTitle:names[i] image:nil identifier:nil handler:^(UIAction *action) {
            StreamFrameViewController *controller = weakSelf;
            if (!controller || !controller->_desktopReady) { return; }
            [controller->_streamView toggleDesktopModifier:keyCode];
            [controller updateDesktopMenu];
        }];
        modifier.state = [_streamView isDesktopModifierHeld:keyCode] ? UIMenuElementStateOn : UIMenuElementStateOff;
        [modifiers addObject:modifier];
    }

    NSDictionary<NSString *, NSArray<NSNumber *> *> *shortcutKeys = @{
        @"Alt+Tab": @[@0xa4, @0x09], @"Copy": @[@0xa2, @0x43], @"Paste": @[@0xa2, @0x56],
        @"Select all": @[@0xa2, @0x41], @"Show desktop": @[@0x5b, @0x44],
        @"File Explorer": @[@0x5b, @0x45], @"Task Manager": @[@0xa2, @0xa0, @0x1b],
        @"Move window left": @[@0x5b, @0xa0, @0x25], @"Move window right": @[@0x5b, @0xa0, @0x27],
        @"Escape": @[@0x1b], @"Tab": @[@0x09], @"Delete": @[@0x2e],
        @"Left": @[@0x25], @"Up": @[@0x26], @"Right": @[@0x27], @"Down": @[@0x28]
    };
    NSArray<UIAction *> *shortcuts = [self desktopShortcutActions:
        @[@"Alt+Tab", @"Copy", @"Paste", @"Select all", @"Show desktop", @"File Explorer",
          @"Task Manager", @"Move window left", @"Move window right", @"Escape", @"Tab", @"Delete",
          @"Left", @"Up", @"Right", @"Down"] keys:shortcutKeys];
    NSArray<UIAction *> *browser = [self desktopShortcutActions:
        @[@"Address bar", @"New tab", @"Find on page", @"Reopen closed tab"] keys:@{
            @"Address bar": @[@0xa2, @0x4c], @"New tab": @[@0xa2, @0x54],
            @"Find on page": @[@0xa2, @0x46], @"Reopen closed tab": @[@0xa2, @0xa0, @0x54],
        }];

    NSMutableArray<UIAction *> *monitors = [NSMutableArray array];
    for (NSInteger index = 0; index < 2; index++) {
        NSString *title = [NSString stringWithFormat:@"Monitor %ld", (long)index + 1];
        [monitors addObject:[UIAction actionWithTitle:title image:nil identifier:nil handler:^(UIAction *action) {
            StreamFrameViewController *controller = weakSelf;
            if (controller && controller->_desktopReady) {
                // Sunshine switches the active capture output on Ctrl+Alt+Shift+Fn.
                [controller->_streamView sendDesktopShortcut:@[@0xa2, @0xa4, @0xa0, @(0x70 + index)]];
            }
        }]];
    }

    NSMutableArray<UIAction *> *capture = [NSMutableArray array];
    NSArray<NSString *> *captureNames = @[@"Match encoded video", @"Standard (16:9)", @"Ultrawide (3440 × 1440)"];
    NSArray<NSNumber *> *captureAspects = @[@0, @(16.0 / 9), @(3440.0 / 1440)];
    for (NSInteger i = 0; i < (NSInteger)captureNames.count; i++) {
        UIAction *choice = [UIAction actionWithTitle:captureNames[i] image:nil identifier:nil handler:^(UIAction *action) {
            StreamFrameViewController *controller = weakSelf;
            if (!controller) { return; }
            controller->_desktopCaptureChoice = i;
            [controller->_streamView setCaptureAspect:captureAspects[i].doubleValue];
            [controller->_streamMan updateRendererLayout];
            [controller updateDesktopMenu];
        }];
        choice.state = _desktopCaptureChoice == i ? UIMenuElementStateOn : UIMenuElementStateOff;
        [capture addObject:choice];
    }

    UIAction *touch = [UIAction actionWithTitle:_desktopDirectTouch ? @"Switch to trackpad" : @"Switch to direct touch"
                                        image:nil identifier:nil handler:^(UIAction *action) {
        StreamFrameViewController *controller = weakSelf;
        if (!controller) { return; }
        controller->_desktopDirectTouch = !controller->_desktopDirectTouch;
        [controller->_streamView setDirectTouch:controller->_desktopDirectTouch];
        [controller updateDesktopMenu];
    }];
    UIAction *fit = [UIAction actionWithTitle:_desktopFill ? @"Fit entire desktop" : @"Fill screen (crop edges)"
                                       image:nil identifier:nil handler:^(UIAction *action) {
        StreamFrameViewController *controller = weakSelf;
        if (!controller) { return; }
        controller->_desktopFill = !controller->_desktopFill;
        [controller->_streamView setFillVideo:controller->_desktopFill];
        [controller->_streamMan updateRendererLayout];
        [controller updateDesktopMenu];
    }];
    UIAction *resolution = [UIAction actionWithTitle:_adaptiveDesktop ? @"Use resolution from Settings" : @"Match window resolution"
                                              image:nil identifier:nil handler:^(UIAction *action) {
        StreamFrameViewController *controller = weakSelf;
        if (!controller || !controller->_desktopReady) { return; }
        controller->_adaptiveDesktop = !controller->_adaptiveDesktop;
        [[NSUserDefaults standardUserDefaults] setBool:!controller->_adaptiveDesktop forKey:@"DesktopUseFixedResolution"];
        [controller restartDesktopStream:@"Changing resolution"];
        [controller updateDesktopMenu];
    }];
    UIAction *text = [UIAction actionWithTitle:@"Send text to PC" image:nil identifier:nil handler:^(UIAction *action) {
        [weakSelf showDesktopTextComposer];
    }];
    UIAction *zoomIn = [UIAction actionWithTitle:@"Zoom in" image:nil identifier:nil handler:^(UIAction *action) {
        [weakSelf zoomDesktopBy:1.5];
    }];
    UIAction *zoomOut = [UIAction actionWithTitle:@"Zoom out" image:nil identifier:nil handler:^(UIAction *action) {
        [weakSelf zoomDesktopBy:1.0 / 1.5];
    }];
    UIAction *resetZoom = [UIAction actionWithTitle:@"Reset zoom" image:nil identifier:nil handler:^(UIAction *action) {
        [weakSelf zoomDesktopBy:0];
    }];
    UIAction *disconnect = [UIAction actionWithTitle:@"Disconnect" image:nil identifier:nil handler:^(UIAction *action) {
        [weakSelf returnToMainFrame];
    }];

    _desktopMenuButton.menu = [UIMenu menuWithChildren:@[
        text,
        [UIMenu menuWithTitle:@"Zoom" children:@[zoomIn, zoomOut, resetZoom]],
        [UIMenu menuWithTitle:@"Layout" children:layouts], touch, fit, resolution,
        [UIMenu menuWithTitle:@"Host display shape" children:capture],
        [UIMenu menuWithTitle:@"Switch monitor" children:monitors],
        [UIMenu menuWithTitle:@"Hold modifiers" children:modifiers],
        [UIMenu menuWithTitle:@"Browser shortcuts" children:browser],
        [UIMenu menuWithTitle:@"Windows shortcuts" children:shortcuts], disconnect
    ]];
}
#endif

- (void)willMoveToParentViewController:(UIViewController *)parent {
    // Only cleanup when we're being destroyed
    if (parent == nil) {
        _leaving = YES;
#if !TARGET_OS_TV
        [_desktopResizeTimer invalidate];
        _desktopResizeTimer = nil;
        [_desktopTrackpad releasePointer];
        [_streamView releaseDesktopInput];
#endif
        [_controllerSupport cleanup];
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        [_streamMan stopStream];
        if (_inactivityTimer != nil) {
            [_inactivityTimer invalidate];
            _inactivityTimer = nil;
        }
        [[NSNotificationCenter defaultCenter] removeObserver:self];
    }
}

- (void)updateStatsOverlay {
    NSString* overlayText = [self->_streamMan getStatsOverlayText];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateOverlayText:overlayText];
    });
}

- (void)updateOverlayText:(NSString*)text {
    if (_overlayView == nil) {
        _overlayView = [[UITextView alloc] init];
#if !TARGET_OS_TV
        [_overlayView setEditable:NO];
#endif
        [_overlayView setUserInteractionEnabled:NO];
        [_overlayView setSelectable:NO];
        [_overlayView setScrollEnabled:NO];
        
        // HACK: If not using stats overlay, center the text
        if (_statsUpdateTimer == nil) {
            [_overlayView setTextAlignment:NSTextAlignmentCenter];
        }
        
        [_overlayView setTextColor:[UIColor lightGrayColor]];
        [_overlayView setBackgroundColor:[UIColor blackColor]];
#if TARGET_OS_TV
        [_overlayView setFont:[UIFont systemFontOfSize:24]];
#else
        [_overlayView setFont:[UIFont systemFontOfSize:12]];
#endif
        [_overlayView setAlpha:0.5];
        [self.view addSubview:_overlayView];
    }
    
    if (text != nil) {
        // We set our bounds to the maximum width in order to work around a bug where
        // sizeToFit interacts badly with the UITextView's line breaks, causing the
        // width to get smaller and smaller each time as more line breaks are inserted.
        [_overlayView setBounds:CGRectMake(self.view.frame.origin.x,
                                           _overlayView.frame.origin.y,
                                           self.view.frame.size.width,
                                           _overlayView.frame.size.height)];
        [_overlayView setText:text];
        [_overlayView sizeToFit];
        [_overlayView setCenter:CGPointMake(self.view.frame.size.width / 2, _overlayView.frame.size.height / 2)];
        [_overlayView setHidden:NO];
    }
    else {
        [_overlayView setHidden:YES];
    }
}

- (void) returnToMainFrame {
    _leaving = YES;
    // Reset display mode back to default
    [self updatePreferredDisplayMode:NO];
    
    [_statsUpdateTimer invalidate];
    _statsUpdateTimer = nil;
    
    [self.navigationController popToRootViewControllerAnimated:YES];
}

// This will fire if the user opens control center or gets a low battery message
- (void)applicationWillResignActive:(NSNotification *)notification {
#if !TARGET_OS_TV
    if (notification.object != self.view.window.windowScene) { return; }
    if (self.streamConfig.desktopMode) {
        [_streamView releaseDesktopInput];
        [_desktopTrackpad releasePointer];
        [self updateDesktopMenu];
    }
#endif
    if (_inactivityTimer != nil) {
        [_inactivityTimer invalidate];
    }
    
#if !TARGET_OS_TV
    // Terminate the stream if the app is inactive for 60 seconds
    Log(LOG_I, @"Starting inactivity termination timer");
    _inactivityTimer = [NSTimer scheduledTimerWithTimeInterval:60
                                                      target:self
                                                    selector:@selector(inactiveTimerExpired:)
                                                    userInfo:nil
                                                     repeats:NO];
#endif
}

- (void)inactiveTimerExpired:(NSTimer*)timer {
    Log(LOG_I, @"Terminating stream after inactivity");

    [self returnToMainFrame];
    
    _inactivityTimer = nil;
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
#if !TARGET_OS_TV
    if (notification.object != self.view.window.windowScene) { return; }
    [self scheduleDesktopResolutionUpdate];
#endif
    // Stop the background timer, since we're foregrounded again
    if (_inactivityTimer != nil) {
        Log(LOG_I, @"Stopping inactivity timer after becoming active again");
        [_inactivityTimer invalidate];
        _inactivityTimer = nil;
    }
}

// This fires when the home button is pressed
- (void)applicationDidEnterBackground:(NSNotification *)notification {
#if !TARGET_OS_TV
    if (notification.object != self.view.window.windowScene) { return; }
#endif
    Log(LOG_I, @"Terminating stream immediately for backgrounding");

    if (_inactivityTimer != nil) {
        [_inactivityTimer invalidate];
        _inactivityTimer = nil;
    }
    
    [self returnToMainFrame];
}

- (void)edgeSwiped {
    Log(LOG_I, @"User swiped to end stream");
    
    [self returnToMainFrame];
}

- (void) connectionStarted {
    Log(LOG_I, @"Connection started");
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_leaving) { return; }
#if !TARGET_OS_TV
        if (self.streamConfig.desktopMode) {
            self->_desktopReady = YES;
            self->_streamView.userInteractionEnabled = YES;
            self->_desktopTrackpad.userInteractionEnabled = YES;
            if (!self.presentedViewController) {
                [self->_streamView becomeFirstResponder];
            }
            [self scheduleDesktopResolutionUpdate];
        }
#endif
        // Leave the spinner spinning until it's obscured by
        // the first frame of video.
        self->_stageLabel.hidden = YES;
        self->_tipLabel.hidden = YES;
        
        [self->_streamView showOnScreenControls];
        
        [self->_controllerSupport connectionEstablished];
        
        if (self->_settings.statsOverlay) {
            self->_statsUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0f
                                                                       target:self
                                                                     selector:@selector(updateStatsOverlay)
                                                                     userInfo:nil
                                                                      repeats:YES];
        }
    });
}

- (void)connectionTerminated:(int)errorCode {
    Log(LOG_I, @"Connection terminated: %d", errorCode);
    
#if !TARGET_OS_TV
    if (self.streamConfig.desktopMode && (errorCode == ML_ERROR_NO_VIDEO_TRAFFIC ||
        errorCode == ML_ERROR_NO_VIDEO_FRAME || errorCode > 0 || errorCode == -1)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_leaving || self->_restartingDesktop) { return; }
            if (self->_desktopReady && self->_automaticRetries > 0 &&
                self.view.window.windowScene.activationState == UISceneActivationStateForegroundActive) {
                self->_automaticRetries--;
                [self restartDesktopStream:@"Reconnecting"];
            } else {
                [self showDesktopConnectionError:@"The connection dropped. Check that Tailscale and the PC are still online."];
            }
        });
        return;
    }
#endif
    unsigned int portFlags = LiGetPortFlagsFromTerminationErrorCode(errorCode);
    unsigned int portTestResults = LiTestClientConnectivity(CONN_TEST_SERVER, 443, portFlags);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_leaving) { return; }
        // Allow the display to go to sleep now
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        
        NSString* title;
        NSString* message;
        
        if (portTestResults != ML_TEST_RESULT_INCONCLUSIVE && portTestResults != 0) {
            title = @"Connection Error";
            message = @"Your device's network connection is blocking Moonlight. Streaming may not work while connected to this network.";
        }
        else {
            switch (errorCode) {
                case ML_ERROR_GRACEFUL_TERMINATION:
                    [self returnToMainFrame];
                    return;
                    
                case ML_ERROR_NO_VIDEO_TRAFFIC:
                    title = @"Connection Error";
                    message = @"No video received from host.";
                    if (portFlags != 0) {
                        char failingPorts[256];
                        LiStringifyPortFlags(portFlags, "\n", failingPorts, sizeof(failingPorts));
                        message = [message stringByAppendingString:[NSString stringWithFormat:@"\n\nCheck your firewall and port forwarding rules for port(s):\n%s", failingPorts]];
                    }
                    break;
                    
                case ML_ERROR_NO_VIDEO_FRAME:
                    title = @"Connection Error";
                    message = @"Your network connection isn't performing well. Reduce your video bitrate setting or try a faster connection.";
                    break;
                    
                case ML_ERROR_UNEXPECTED_EARLY_TERMINATION:
                case ML_ERROR_PROTECTED_CONTENT:
                    title = @"Connection Error";
                    message = @"Something went wrong on your host PC when starting the stream.\n\nMake sure you don't have any DRM-protected content open on your host PC. You can also try restarting your host PC.\n\nIf the issue persists, try reinstalling your GPU drivers and GeForce Experience.";
                    break;
                    
                case ML_ERROR_FRAME_CONVERSION:
                    title = @"Connection Error";
                    message = @"The host PC reported a fatal video encoding error.\n\nTry disabling HDR mode, changing the streaming resolution, or changing your host PC's display resolution.";
                    break;
                    
                default:
                {
                    NSString* errorString;
                    if (abs(errorCode) > 1000) {
                        // We'll assume large errors are hex values
                        errorString = [NSString stringWithFormat:@"%08X", (uint32_t)errorCode];
                    }
                    else {
                        // Smaller values will just be printed as decimal (probably errno.h values)
                        errorString = [NSString stringWithFormat:@"%d", errorCode];
                    }
                    
                    title = @"Connection Terminated";
                    message = [NSString stringWithFormat: @"The connection was terminated\n\nError code: %@", errorString];
                    break;
                }
            }
        }
        
        UIAlertController* conTermAlert = [UIAlertController alertControllerWithTitle:title
                                                                              message:message
                                                                       preferredStyle:UIAlertControllerStyleAlert];
        [Utils addHelpOptionToDialog:conTermAlert];
        [conTermAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            [self returnToMainFrame];
        }]];
        [self presentViewController:conTermAlert animated:YES completion:nil];
    });

    [_streamMan stopStream];
}

- (void) stageStarting:(const char*)stageName {
    Log(LOG_I, @"Starting %s", stageName);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString* lowerCase = [NSString stringWithFormat:@"%s in progress...", stageName];
        NSString* titleCase = [[[lowerCase substringToIndex:1] uppercaseString] stringByAppendingString:[lowerCase substringFromIndex:1]];
        [self->_stageLabel setText:titleCase];
        [self->_stageLabel sizeToFit];
        self->_stageLabel.center = CGPointMake(self.view.frame.size.width / 2, self->_stageLabel.center.y);
    });
}

- (void) stageComplete:(const char*)stageName {
}

- (void) stageFailed:(const char*)stageName withError:(int)errorCode portTestFlags:(int)portTestFlags {
    Log(LOG_I, @"Stage %s failed: %d", stageName, errorCode);
    
#if !TARGET_OS_TV
    if (self.streamConfig.desktopMode) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_leaving || self->_restartingDesktop) { return; }
            [self showDesktopConnectionError:[NSString stringWithFormat:@"%s failed with error %d", stageName, errorCode]];
        });
        return;
    }
#endif
    unsigned int portTestResults = LiTestClientConnectivity(CONN_TEST_SERVER, 443, portTestFlags);

    dispatch_async(dispatch_get_main_queue(), ^{
        // Allow the display to go to sleep now
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        
        NSString* message = [NSString stringWithFormat:@"%s failed with error %d", stageName, errorCode];
        if (portTestFlags != 0) {
            char failingPorts[256];
            LiStringifyPortFlags(portTestFlags, "\n", failingPorts, sizeof(failingPorts));
            message = [message stringByAppendingString:[NSString stringWithFormat:@"\n\nCheck your firewall and port forwarding rules for port(s):\n%s", failingPorts]];
        }
        if (portTestResults != ML_TEST_RESULT_INCONCLUSIVE && portTestResults != 0) {
            message = [message stringByAppendingString:@"\n\nYour device's network connection is blocking Moonlight. Streaming may not work while connected to this network."];
        }
        
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Connection Failed"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [Utils addHelpOptionToDialog:alert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            [self returnToMainFrame];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    });
    
    [_streamMan stopStream];
}

- (void) launchFailed:(NSString*)message {
    Log(LOG_I, @"Launch failed: %@", message);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // Allow the display to go to sleep now
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        
        if (self->_leaving) { return; }
#if !TARGET_OS_TV
        if (self.streamConfig.desktopMode) {
            if (!self->_restartingDesktop) { [self showDesktopConnectionError:message]; }
            return;
        }
#endif
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Connection Error"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [Utils addHelpOptionToDialog:alert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            [self returnToMainFrame];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

#if !TARGET_OS_TV
- (void)showDesktopConnectionError:(NSString *)message {
    _desktopReady = NO;
    [_streamView releaseDesktopInput];
    [_desktopTrackpad releasePointer];
    _streamView.userInteractionEnabled = NO;
    _desktopTrackpad.userInteractionEnabled = NO;
    [_streamMan stopStream];
    [_spinner stopAnimating];
    [_statsUpdateTimer invalidate];
    _statsUpdateTimer = nil;
    [UIApplication sharedApplication].idleTimerDisabled = NO;
    if (self.presentedViewController) {
        _deferredDesktopConnectionError = message;
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Desktop connection"
                                                                    message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Retry" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self restartDesktopStream:@"Reconnecting"];
    }]];
    if (_adaptiveDesktop) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Retry at Settings resolution" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            self->_adaptiveDesktop = NO;
            [self updateDesktopMenu];
            [self restartDesktopStream:@"Reconnecting"];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Disconnect" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        [self returnToMainFrame];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
#endif

- (void)rumble:(unsigned short)controllerNumber lowFreqMotor:(unsigned short)lowFreqMotor highFreqMotor:(unsigned short)highFreqMotor {
    Log(LOG_I, @"Rumble on gamepad %d: %04x %04x", controllerNumber, lowFreqMotor, highFreqMotor);
    
    [_controllerSupport rumble:controllerNumber lowFreqMotor:lowFreqMotor highFreqMotor:highFreqMotor];
}

- (void) rumbleTriggers:(uint16_t)controllerNumber leftTrigger:(uint16_t)leftTrigger rightTrigger:(uint16_t)rightTrigger {
    Log(LOG_I, @"Trigger rumble on gamepad %d: %04x %04x", controllerNumber, leftTrigger, rightTrigger);
    
    [_controllerSupport rumbleTriggers:controllerNumber leftTrigger:leftTrigger rightTrigger:rightTrigger];
}

- (void) setMotionEventState:(uint16_t)controllerNumber motionType:(uint8_t)motionType reportRateHz:(uint16_t)reportRateHz {
    Log(LOG_I, @"Set motion state on gamepad %d: %02x %u Hz", controllerNumber, motionType, reportRateHz);
    
    [_controllerSupport setMotionEventState:controllerNumber motionType:motionType reportRateHz:reportRateHz];
}

- (void) setControllerLed:(uint16_t)controllerNumber r:(uint8_t)r g:(uint8_t)g b:(uint8_t)b {
    Log(LOG_I, @"Set controller LED on gamepad %d: l%02x%02x%02x", controllerNumber, r, g, b);
    
    [_controllerSupport setControllerLed:controllerNumber r:r g:g b:b];
}

- (void)connectionStatusUpdate:(int)status {
    Log(LOG_W, @"Connection status update: %d", status);

    // The stats overlay takes precedence over these warnings
    if (_statsUpdateTimer != nil) {
        return;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        switch (status) {
            case CONN_STATUS_OKAY:
                [self updateOverlayText:nil];
                break;
                
            case CONN_STATUS_POOR:
                if (self->_streamConfig.bitRate > 5000) {
                    [self updateOverlayText:@"Slow connection to PC\nReduce your bitrate"];
                }
                else {
                    [self updateOverlayText:@"Poor connection to PC"];
                }
                break;
        }
    });
}

- (void) updatePreferredDisplayMode:(BOOL)streamActive {
#if TARGET_OS_TV
    if (@available(tvOS 11.2, *)) {
        UIWindow* window = [[[UIApplication sharedApplication] delegate] window];
        AVDisplayManager* displayManager = [window avDisplayManager];
        
        // This logic comes from Kodi and MrMC
        if (streamActive) {
            int dynamicRange;
            
            if (LiGetCurrentHostDisplayHdrMode()) {
                dynamicRange = 2; // HDR10
            }
            else {
                dynamicRange = 0; // SDR
            }
            
            AVDisplayCriteria* displayCriteria = [[AVDisplayCriteria alloc] initWithRefreshRate:[_settings.framerate floatValue]
                                                                              videoDynamicRange:dynamicRange];
            displayManager.preferredDisplayCriteria = displayCriteria;
        }
        else {
            // Switch back to the default display mode
            displayManager.preferredDisplayCriteria = nil;
        }
    }
#endif
}

- (void) setHdrMode:(bool)enabled {
    Log(LOG_I, @"HDR is now: %s", enabled ? "active" : "inactive");
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updatePreferredDisplayMode:YES];
    });
}

- (void) videoContentShown {
    [_spinner stopAnimating];
    [self.view setBackgroundColor:[UIColor blackColor]];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)gamepadPresenceChanged {
#if !TARGET_OS_TV
    if (@available(iOS 11.0, *)) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }
#endif
}

- (void)mousePresenceChanged {
#if !TARGET_OS_TV
    if (@available(iOS 14.0, *)) {
        [self setNeedsUpdateOfPrefersPointerLocked];
    }
#endif
}

- (void) streamExitRequested {
    Log(LOG_I, @"Gamepad combo requested stream exit");
    
    [self returnToMainFrame];
}

- (void)userInteractionBegan {
    // Disable hiding home bar when user is interacting.
    // iOS will force it to be shown anyway, but it will
    // also discard our edges deferring system gestures unless
    // we willingly give up home bar hiding preference.
    _userIsInteracting = YES;
#if !TARGET_OS_TV
    if (@available(iOS 11.0, *)) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }
#endif
}

- (void)userInteractionEnded {
    // Enable home bar hiding again if conditions allow
    _userIsInteracting = NO;
#if !TARGET_OS_TV
    [self scheduleDesktopResolutionUpdate];
    if (@available(iOS 11.0, *)) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }
#endif
}

#if !TARGET_OS_TV
// Require a confirmation when streaming to activate a system gesture
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures {
    return UIRectEdgeAll;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
    if ([_controllerSupport getConnectedGamepadCount] > 0 &&
        [_streamView getCurrentOscState] == OnScreenControlsLevelOff &&
        _userIsInteracting == NO) {
        // Autohide the home bar when a gamepad is connected
        // and the on-screen controls are disabled. We can't
        // do this all the time because any touch on the display
        // will cause the home indicator to reappear, and our
        // preferredScreenEdgesDeferringSystemGestures will also
        // be suppressed (leading to possible errant exits of the
        // stream).
        return YES;
    }
    
    return NO;
}

- (BOOL)shouldAutorotate {
    return YES;
}

- (BOOL)prefersPointerLocked {
    // Pointer lock breaks the UIKit mouse APIs, which is a problem because
    // GCMouse is horribly broken on iOS 14.0 for certain mice. Only lock
    // the cursor if there is a GCMouse present.
    return [GCMouse mice].count > 0;
}
#endif

@end
