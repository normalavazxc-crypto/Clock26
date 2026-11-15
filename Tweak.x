// Clock26/Tweak.x — iOS 16 Lock Screen stretchable clock (iOS 26 style)
// Supports SpringBoard (Lock Screen), PosterBoard (Lock Screen Customize), and Settings live sync.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static CFStringRef const kClock26PrefsDomain = CFSTR("com.clock26.tweak");
static CFStringRef const kClock26NotifyName = CFSTR("com.clock26.tweak/PrefsChanged");

static CGFloat const kMinScaleY = 1.0;
static CGFloat const kMaxScaleY = 3.0;
static CGFloat const kDefaultScaleY = 1.85;

static BOOL gEnabled = YES;
static BOOL gLockscreenDrag = YES;
static CGFloat gScaleY = 1.85;
static BOOL gIsPosterBoard = NO;

// Track active time views so Darwin notifications update all live instances immediately
static NSHashTable<UIView *> *gTrackedTimeViews = nil;

// ---------------------------------------------------------------------------
// Private CoverSheet / PosterBoard interfaces (iOS 16)
// ---------------------------------------------------------------------------

@interface CSProminentTextView : UIView
@property (nonatomic, strong) UILabel *textLabel;
@property (nonatomic, strong) UIFont *primaryFont;
@end

@interface CSProminentTimeView : CSProminentTextView
@end

@interface CSProminentDisplayViewController : UIViewController
@end

@interface SBFLockScreenDateView : UIView
@end

// ---------------------------------------------------------------------------
// Preferences & Darwin Notification Sync
// ---------------------------------------------------------------------------

static void Clock26LoadPrefs(void) {
    CFPreferencesAppSynchronize(kClock26PrefsDomain);

    CFPropertyListRef enabledRef = CFPreferencesCopyAppValue(CFSTR("enabled"), kClock26PrefsDomain);
    gEnabled = enabledRef ? [(__bridge NSNumber *)enabledRef boolValue] : YES;
    if (enabledRef) CFRelease(enabledRef);

    CFPropertyListRef dragRef = CFPreferencesCopyAppValue(CFSTR("lockscreenDrag"), kClock26PrefsDomain);
    gLockscreenDrag = dragRef ? [(__bridge NSNumber *)dragRef boolValue] : YES;
    if (dragRef) CFRelease(dragRef);

    CFPropertyListRef scaleRef = CFPreferencesCopyAppValue(CFSTR("scaleY"), kClock26PrefsDomain);
    if (scaleRef) {
        CGFloat s = [(__bridge NSNumber *)scaleRef doubleValue];
        gScaleY = MAX(kMinScaleY, MIN(kMaxScaleY, s));
        CFRelease(scaleRef);
    } else {
        gScaleY = kDefaultScaleY;
    }
}

static void Clock26SaveScaleY(CGFloat scaleY) {
    gScaleY = MAX(kMinScaleY, MIN(kMaxScaleY, scaleY));
    CFPreferencesSetAppValue(CFSTR("scaleY"), (__bridge CFPropertyListRef)@(gScaleY), kClock26PrefsDomain);
    CFPreferencesAppSynchronize(kClock26PrefsDomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         kClock26NotifyName,
                                         NULL, NULL, YES);
}

static void Clock26DisableClippingUpwards(UIView *view, NSUInteger levels) {
    UIView *cur = view;
    for (NSUInteger i = 0; i < levels && cur; i++) {
        cur.clipsToBounds = NO;
        cur.layer.masksToBounds = NO;
        cur = cur.superview;
    }
}

static void Clock26ApplyVerticalScale(UIView *timeView, CGFloat scaleY) {
    if (!timeView) return;

    if (!gEnabled) {
        timeView.transform = CGAffineTransformIdentity;
        return;
    }

    CGFloat clamped = MAX(kMinScaleY, MIN(kMaxScaleY, scaleY));
    CGFloat height = CGRectGetHeight(timeView.bounds);
    CGFloat translateY = (height * (clamped - 1.0)) * 0.5;

    CGAffineTransform scale = CGAffineTransformMakeScale(1.0, clamped);
    CGAffineTransform translate = CGAffineTransformMakeTranslation(0.0, translateY);
    timeView.transform = CGAffineTransformConcat(scale, translate);

    Clock26DisableClippingUpwards(timeView, 5);
}

// ---------------------------------------------------------------------------
// Interactive drag handle overlay
// ---------------------------------------------------------------------------

@interface Clock26ResizeController : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIView *targetView;
@property (nonatomic, strong) UIView *handleContainer;
@property (nonatomic, strong) UILabel *badgeLabel;
@property (nonatomic, assign) BOOL editing;
@property (nonatomic, assign) CGFloat panStartScaleY;
@property (nonatomic, strong) NSTimer *autoHideTimer;
@property (nonatomic, strong) UIImpactFeedbackGenerator *haptic;
@property (nonatomic, assign) BOOL snappedToDefault;
@end

@implementation Clock26ResizeController

- (instancetype)initWithTargetView:(UIView *)targetView {
    self = [super init];
    if (self) {
        _targetView = targetView;
        _haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [self setupGestures];
        [self setupHandleUI];
    }
    return self;
}

- (void)setupGestures {
    UIView *v = self.targetView;
    if (!v) return;
    v.userInteractionEnabled = YES;

    if (!gIsPosterBoard) {
        UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc]
            initWithTarget:self action:@selector(handleLongPress:)];
        longPress.minimumPressDuration = 0.35;
        longPress.delegate = self;
        [v addGestureRecognizer:longPress];
    }
}

- (void)setupHandleUI {
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 148, 38)];
    container.alpha = 0.0;
    container.hidden = YES;
    container.userInteractionEnabled = YES;

    UIVisualEffectView *blur = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
    blur.frame = container.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blur.layer.cornerRadius = 19.0;
    blur.clipsToBounds = YES;
    [container addSubview:blur];

    // Up/down arrows + grabber bar
    UIView *pill = [[UIView alloc] initWithFrame:CGRectMake(14, 16, 44, 5)];
    pill.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.92];
    pill.layer.cornerRadius = 2.5;
    [container addSubview:pill];

    UILabel *badge = [[UILabel alloc] initWithFrame:CGRectMake(64, 0, 72, 38)];
    badge.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightSemibold];
    badge.textColor = [UIColor whiteColor];
    badge.textAlignment = NSTextAlignmentCenter;
    badge.text = [NSString stringWithFormat:@"%.2fx", gScaleY];
    [container addSubview:badge];
    self.badgeLabel = badge;

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(handlePan:)];
    pan.delegate = self;
    [container addGestureRecognizer:pan];

    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleDoubleTap:)];
    doubleTap.numberOfTapsRequired = 2;
    [container addGestureRecognizer:doubleTap];

    self.handleContainer = container;
}

- (void)attachHandleIfNeeded {
    UIView *v = self.targetView;
    UIView *host = v.superview;
    if (!v || !host) return;
    if (self.handleContainer.superview != host) {
        [host addSubview:self.handleContainer];
    }
    [self layoutHandle];
}

- (void)layoutHandle {
    UIView *v = self.targetView;
    if (!v || !self.handleContainer.superview) return;

    CGRect transformedFrame = v.frame;
    CGFloat cx = CGRectGetMidX(transformedFrame);
    CGFloat bottomY = CGRectGetMaxY(transformedFrame) + 16.0;
    CGFloat superH = CGRectGetHeight(self.handleContainer.superview.bounds);
    if (superH > 100.0) {
        CGFloat maxY = superH - 50.0;
        if (bottomY > maxY) bottomY = maxY;
    }

    self.handleContainer.center = CGPointMake(cx, bottomY);
    self.badgeLabel.text = [NSString stringWithFormat:@"%.2fx", gScaleY];
}

- (void)showPersistentInCustomize {
    if (!gEnabled) {
        self.handleContainer.hidden = YES;
        self.handleContainer.alpha = 0.0;
        return;
    }
    [self attachHandleIfNeeded];
    self.editing = YES;
    self.handleContainer.hidden = NO;
    self.handleContainer.alpha = 1.0;
    [self.handleContainer.superview bringSubviewToFront:self.handleContainer];
}

- (void)setEditing:(BOOL)editing {
    if (_editing == editing) return;
    _editing = editing;

    if (editing) {
        [self attachHandleIfNeeded];
        self.handleContainer.hidden = NO;
        [self.handleContainer.superview bringSubviewToFront:self.handleContainer];
        [UIView animateWithDuration:0.22 animations:^{
            self.handleContainer.alpha = 1.0;
        }];
        if (!gIsPosterBoard) {
            [self resetAutoHideTimer];
        }
    } else {
        [self.autoHideTimer invalidate];
        self.autoHideTimer = nil;
        Clock26SaveScaleY(gScaleY);
        [UIView animateWithDuration:0.22 animations:^{
            self.handleContainer.alpha = 0.0;
        } completion:^(BOOL finished) {
            if (!self.editing) {
                self.handleContainer.hidden = YES;
            }
        }];
    }
}

- (void)resetAutoHideTimer {
    if (gIsPosterBoard) return;
    [self.autoHideTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.autoHideTimer = [NSTimer scheduledTimerWithTimeInterval:4.5
                                                         repeats:NO
                                                           block:^(NSTimer * _Nonnull timer) {
        [weakSelf setEditing:NO];
    }];
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gr {
    if (!gEnabled || !gLockscreenDrag) return;
    if (gr.state == UIGestureRecognizerStateBegan) {
        [self.haptic prepare];
        [self.haptic impactOccurred];
        [self setEditing:!self.editing];
    }
}

- (void)handlePan:(UIPanGestureRecognizer *)gr {
    UIView *v = self.targetView;
    if (!v || !gEnabled) return;

    if (gr.state == UIGestureRecognizerStateBegan) {
        [self.autoHideTimer invalidate];
        [self.haptic prepare];
        self.panStartScaleY = gScaleY;
        self.snappedToDefault = NO;
    } else if (gr.state == UIGestureRecognizerStateChanged) {
        CGPoint translation = [gr translationInView:v.superview];
        CGFloat baseHeight = MAX(60.0, CGRectGetHeight(v.bounds));
        CGFloat deltaScale = translation.y / baseHeight;
        CGFloat nextScale = MAX(kMinScaleY, MIN(kMaxScaleY, self.panStartScaleY + deltaScale));

        if (fabs(nextScale - 1.0) < 0.04) {
            nextScale = 1.0;
            if (!self.snappedToDefault) {
                [self.haptic impactOccurred];
                self.snappedToDefault = YES;
            }
        } else {
            self.snappedToDefault = NO;
        }

        gScaleY = nextScale;
        Clock26ApplyVerticalScale(v, gScaleY);
        [self layoutHandle];
    } else if (gr.state == UIGestureRecognizerStateEnded ||
               gr.state == UIGestureRecognizerStateCancelled) {
        Clock26SaveScaleY(gScaleY);
        [self resetAutoHideTimer];
    }
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)gr {
    if (!gEnabled) return;
    [self.haptic impactOccurred];
    gScaleY = (fabs(gScaleY - kDefaultScaleY) < 0.05) ? 1.0 : kDefaultScaleY;
    [UIView animateWithDuration:0.28
                          delay:0
         usingSpringWithDamping:0.82
          initialSpringVelocity:0.4
                        options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        Clock26ApplyVerticalScale(self.targetView, gScaleY);
        [self layoutHandle];
    } completion:nil];
    Clock26SaveScaleY(gScaleY);
    [self resetAutoHideTimer];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return NO;
}

@end

static char kClock26ControllerKey;

static Clock26ResizeController *Clock26ControllerForView(UIView *view) {
    Clock26ResizeController *ctrl = objc_getAssociatedObject(view, &kClock26ControllerKey);
    if (!ctrl) {
        ctrl = [[Clock26ResizeController alloc] initWithTargetView:view];
        objc_setAssociatedObject(view, &kClock26ControllerKey, ctrl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!gTrackedTimeViews) {
            gTrackedTimeViews = [NSHashTable weakObjectsHashTable];
        }
        [gTrackedTimeViews addObject:view];
    }
    return ctrl;
}

static void Clock26RefreshAllViews(void) {
    Clock26LoadPrefs();
    for (UIView *v in gTrackedTimeViews) {
        if (!v) continue;
        Clock26ApplyVerticalScale(v, gScaleY);
        Clock26ResizeController *ctrl = objc_getAssociatedObject(v, &kClock26ControllerKey);
        if (ctrl) {
            if (gIsPosterBoard) {
                [ctrl showPersistentInCustomize];
            } else {
                [ctrl layoutHandle];
            }
        }
    }
}

static void Clock26PrefsChangedCallback(CFNotificationCenterRef center,
                                        void *observer,
                                        CFStringRef name,
                                        const void *object,
                                        CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        Clock26RefreshAllViews();
    });
}

// ---------------------------------------------------------------------------
// Hooks: CSProminentTimeView (SpringBoard + PosterBoard Customize)
// ---------------------------------------------------------------------------

%hook CSProminentTimeView

- (void)layoutSubviews {
    %orig;
    Clock26ResizeController *ctrl = Clock26ControllerForView(self);
    Clock26ApplyVerticalScale(self, gScaleY);
    if (gIsPosterBoard) {
        [ctrl showPersistentInCustomize];
    } else if (ctrl.editing) {
        [ctrl layoutHandle];
    }
}

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        Clock26LoadPrefs();
        Clock26ResizeController *ctrl = Clock26ControllerForView(self);
        Clock26ApplyVerticalScale(self, gScaleY);
        if (gIsPosterBoard) {
            [ctrl showPersistentInCustomize];
        }
    }
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = %orig;
    if (hit) return hit;

    Clock26ResizeController *ctrl = objc_getAssociatedObject(self, &kClock26ControllerKey);
    if (ctrl && ctrl.editing && !ctrl.handleContainer.hidden) {
        CGPoint handlePt = [self convertPoint:point toView:ctrl.handleContainer];
        if ([ctrl.handleContainer pointInside:handlePt withEvent:event]) {
            return ctrl.handleContainer;
        }
    }
    return nil;
}

%end

// Ensure parent prominent display view controller never clips and forwards handle taps
%hook CSProminentDisplayViewController

- (void)viewDidLayoutSubviews {
    %orig;
    self.view.clipsToBounds = NO;
    self.view.layer.masksToBounds = NO;
}

%end

%hook SBFLockScreenDateView

- (void)layoutSubviews {
    %orig;
    Clock26DisableClippingUpwards(self, 3);
}

%end

%ctor {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        gIsPosterBoard = [bundleID isEqualToString:@"com.apple.PosterBoard"];

        Clock26LoadPrefs();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        Clock26PrefsChangedCallback,
                                        kClock26NotifyName,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        %init;
    }
}
