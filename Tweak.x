// Clock26/Tweak.x — iOS 16 Lock Screen stretchable clock (iOS 26 style)

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static NSString *const kClock26ScaleKey = @"Clock26_TimeScaleY";
static CGFloat const kMinScaleY = 1.0;
static CGFloat const kMaxScaleY = 3.0;
static CGFloat const kDefaultScaleY = 1.85;

// ---------------------------------------------------------------------------
// Private CoverSheet / SpringBoardFoundation interfaces (iOS 16)
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
// Shared preferences & state helpers
// ---------------------------------------------------------------------------

static CGFloat Clock26LoadScaleY(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    id val = [defaults objectForKey:kClock26ScaleKey];
    if (!val) return kDefaultScaleY;
    CGFloat s = [val doubleValue];
    if (s < kMinScaleY) return kMinScaleY;
    if (s > kMaxScaleY) return kMaxScaleY;
    return s;
}

static void Clock26SaveScaleY(CGFloat scaleY) {
    CGFloat clamped = MAX(kMinScaleY, MIN(kMaxScaleY, scaleY));
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setDouble:clamped forKey:kClock26ScaleKey];
    [defaults synchronize];
}

static void Clock26DisableClippingUpwards(UIView *view, NSUInteger levels) {
    UIView *cur = view;
    for (NSUInteger i = 0; i < levels && cur; i++) {
        cur.clipsToBounds = NO;
        cur.layer.masksToBounds = NO;
        cur = cur.superview;
    }
}

// Applies vertical stretch anchored to the top edge of the time view so
// digits grow downward under the date label without overlapping it.
static void Clock26ApplyVerticalScale(UIView *timeView, CGFloat scaleY) {
    if (!timeView) return;

    CGFloat clamped = MAX(kMinScaleY, MIN(kMaxScaleY, scaleY));
    CGFloat height = CGRectGetHeight(timeView.bounds);

    // Keep top edge pinned: translate down by half the extra height.
    CGFloat translateY = (height * (clamped - 1.0)) * 0.5;
    CGAffineTransform scale = CGAffineTransformMakeScale(1.0, clamped);
    CGAffineTransform translate = CGAffineTransformMakeTranslation(0.0, translateY);
    timeView.transform = CGAffineTransformConcat(scale, translate);

    Clock26DisableClippingUpwards(timeView, 4);
}

// ---------------------------------------------------------------------------
// Interactive drag handle overlay attached to CSProminentTimeView
// ---------------------------------------------------------------------------

@interface Clock26ResizeController : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIView *targetView;
@property (nonatomic, strong) UIView *handleContainer;
@property (nonatomic, strong) UIView *grabberPill;
@property (nonatomic, strong) UILabel *badgeLabel;
@property (nonatomic, assign) BOOL editing;
@property (nonatomic, assign) CGFloat currentScaleY;
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
        _currentScaleY = Clock26LoadScaleY();
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

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleLongPress:)];
    longPress.minimumPressDuration = 0.35;
    longPress.delegate = self;
    [v addGestureRecognizer:longPress];
}

- (void)setupHandleUI {
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 140, 38)];
    container.alpha = 0.0;
    container.hidden = YES;
    container.userInteractionEnabled = YES;

    // Translucent pill background
    UIVisualEffectView *blur = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
    blur.frame = container.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blur.layer.cornerRadius = 19.0;
    blur.clipsToBounds = YES;
    [container addSubview:blur];

    // Grabber bar
    UIView *pill = [[UIView alloc] initWithFrame:CGRectMake(14, 16, 44, 5)];
    pill.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.9];
    pill.layer.cornerRadius = 2.5;
    [container addSubview:pill];
    self.grabberPill = pill;

    // Live scale indicator
    UILabel *badge = [[UILabel alloc] initWithFrame:CGRectMake(64, 0, 66, 38)];
    badge.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightSemibold];
    badge.textColor = [UIColor whiteColor];
    badge.textAlignment = NSTextAlignmentCenter;
    badge.text = [NSString stringWithFormat:@"%.2fx", self.currentScaleY];
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

    // Position handle right below the stretched clock frame.
    CGRect transformedFrame = v.frame;
    CGFloat cx = CGRectGetMidX(transformedFrame);
    CGFloat bottomY = CGRectGetMaxY(transformedFrame) + 14.0;
    CGFloat maxY = CGRectGetHeight(self.handleContainer.superview.bounds) - 60.0;
    if (bottomY > maxY) bottomY = maxY;

    // Compensate for any parent transform on handle itself (keep handle 1:1).
    self.handleContainer.center = CGPointMake(cx, bottomY);
    self.badgeLabel.text = [NSString stringWithFormat:@"%.2fx", self.currentScaleY];
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
        [self resetAutoHideTimer];
    } else {
        [self.autoHideTimer invalidate];
        self.autoHideTimer = nil;
        Clock26SaveScaleY(self.currentScaleY);
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
    [self.autoHideTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.autoHideTimer = [NSTimer scheduledTimerWithTimeInterval:4.5
                                                         repeats:NO
                                                           block:^(NSTimer * _Nonnull timer) {
        [weakSelf setEditing:NO];
    }];
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gr {
    if (gr.state == UIGestureRecognizerStateBegan) {
        [self.haptic prepare];
        [self.haptic impactOccurred];
        [self setEditing:!self.editing];
    }
}

- (void)handlePan:(UIPanGestureRecognizer *)gr {
    UIView *v = self.targetView;
    if (!v) return;

    if (gr.state == UIGestureRecognizerStateBegan) {
        [self.autoHideTimer invalidate];
        [self.haptic prepare];
        self.panStartScaleY = self.currentScaleY;
        self.snappedToDefault = NO;
    } else if (gr.state == UIGestureRecognizerStateChanged) {
        CGPoint translation = [gr translationInView:v.superview];
        CGFloat baseHeight = MAX(60.0, CGRectGetHeight(v.bounds));
        CGFloat deltaScale = translation.y / baseHeight;
        CGFloat nextScale = MAX(kMinScaleY, MIN(kMaxScaleY, self.panStartScaleY + deltaScale));

        // Gentle magnetic snap at 1.0x
        if (fabs(nextScale - 1.0) < 0.04) {
            nextScale = 1.0;
            if (!self.snappedToDefault) {
                [self.haptic impactOccurred];
                self.snappedToDefault = YES;
            }
        } else {
            self.snappedToDefault = NO;
        }

        self.currentScaleY = nextScale;
        Clock26ApplyVerticalScale(v, nextScale);
        [self layoutHandle];
    } else if (gr.state == UIGestureRecognizerStateEnded ||
               gr.state == UIGestureRecognizerStateCancelled) {
        Clock26SaveScaleY(self.currentScaleY);
        [self resetAutoHideTimer];
    }
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)gr {
    [self.haptic impactOccurred];
    self.currentScaleY = (fabs(self.currentScaleY - kDefaultScaleY) < 0.05) ? 1.0 : kDefaultScaleY;
    [UIView animateWithDuration:0.28
                          delay:0
         usingSpringWithDamping:0.82
          initialSpringVelocity:0.4
                        options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        Clock26ApplyVerticalScale(self.targetView, self.currentScaleY);
        [self layoutHandle];
    } completion:nil];
    Clock26SaveScaleY(self.currentScaleY);
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
    }
    return ctrl;
}

// ---------------------------------------------------------------------------
// Hooks: CSProminentTimeView (iOS 16 CoverSheet clock)
// ---------------------------------------------------------------------------

%hook CSProminentTimeView

- (void)layoutSubviews {
    %orig;
    Clock26ResizeController *ctrl = Clock26ControllerForView(self);
    Clock26ApplyVerticalScale(self, ctrl.currentScaleY);
    if (ctrl.editing) {
        [ctrl layoutHandle];
    }
}

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        Clock26ResizeController *ctrl = Clock26ControllerForView(self);
        ctrl.currentScaleY = Clock26LoadScaleY();
        Clock26ApplyVerticalScale(self, ctrl.currentScaleY);
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

// Ensure parent prominent display view controller never clips the stretched clock
%hook CSProminentDisplayViewController

- (void)viewDidLayoutSubviews {
    %orig;
    self.view.clipsToBounds = NO;
    self.view.layer.masksToBounds = NO;
}

%end

// Fallback for devices/views still using SBFLockScreenDateView
%hook SBFLockScreenDateView

- (void)layoutSubviews {
    %orig;
    Clock26DisableClippingUpwards(self, 3);
}

%end

%ctor {
    @autoreleasepool {
        %init;
    }
}
