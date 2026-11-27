//
//  LPLockViewController.m
//  LPSimpleExample
//

#import "LPLockViewController.h"
#import <LocalAuthentication/LocalAuthentication.h>

static NSString *const LPLockDefaultMessage = @"Unlock to continue.";

#pragma mark - Brand palette

// Dark green branding. Only UIKit / CoreGraphics are used on this screen so
// the target does not need to link QuartzCore.
static UIColor *LPBrandGreen(void)       { return [UIColor colorWithRed:11/255.0  green:61/255.0  blue:46/255.0  alpha:1]; } // #0B3D2E
static UIColor *LPBrandGreenDeep(void)   { return [UIColor colorWithRed:4/255.0   green:30/255.0  blue:22/255.0  alpha:1]; } // #041E16
static UIColor *LPBrandMint(void)        { return [UIColor colorWithRed:126/255.0 green:217/255.0 blue:164/255.0 alpha:1]; } // #7ED9A4
static UIColor *LPBrandTextMuted(void)   { return [UIColor colorWithRed:190/255.0 green:222/255.0 blue:204/255.0 alpha:1]; } // #BEDECC

static const CGFloat LPBadgeSize = 112;
static const CGFloat LPButtonHeight = 50;

static BOOL LPReduceMotionEnabled(void) {
    if (@available(iOS 8.0, *)) {
        return UIAccessibilityIsReduceMotionEnabled();
    }
    return NO;
}

#pragma mark - Drawn views

// Full-screen vertical gradient, top to bottom.
@interface LPLockGradientView : UIView
@end

@implementation LPLockGradientView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = LPBrandGreenDeep();
        self.contentMode = UIViewContentModeRedraw;
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    NSArray *colors = @[(__bridge id)LPBrandGreen().CGColor,
                        (__bridge id)LPBrandGreenDeep().CGColor];
    CGFloat locations[] = {0, 1};
    CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, locations);
    CGContextDrawLinearGradient(context, gradient,
                                CGPointZero,
                                CGPointMake(0, CGRectGetHeight(self.bounds)),
                                0);
    CGGradientRelease(gradient);
    CGColorSpaceRelease(space);
}

@end

// The U-shaped shackle of the padlock. Separate from the body so it can lift.
@interface LPLockShackleView : UIView
@end

@implementation LPLockShackleView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.opaque = NO;
        self.backgroundColor = [UIColor clearColor];
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    CGFloat lineWidth = 6;
    CGFloat inset = lineWidth / 2;
    CGFloat width = CGRectGetWidth(self.bounds);
    CGFloat height = CGRectGetHeight(self.bounds);
    CGFloat radius = width / 2 - inset;

    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:CGPointMake(inset, height)];
    [path addLineToPoint:CGPointMake(inset, inset + radius)];
    [path addArcWithCenter:CGPointMake(width / 2, inset + radius)
                    radius:radius
                startAngle:M_PI
                  endAngle:2 * M_PI
                 clockwise:YES];
    [path addLineToPoint:CGPointMake(width - inset, height)];
    path.lineWidth = lineWidth;
    [[UIColor whiteColor] setStroke];
    [path stroke];
}

@end

// The padlock body with a keyhole cut out of it.
@interface LPLockBodyView : UIView
@end

@implementation LPLockBodyView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.opaque = NO;
        self.backgroundColor = [UIColor clearColor];
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGRect bounds = self.bounds;

    [[UIColor whiteColor] setFill];
    [[UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:10] fill];

    // Punch the keyhole through so the badge shows behind it.
    CGContextSetBlendMode(context, kCGBlendModeClear);
    CGPoint center = CGPointMake(CGRectGetMidX(bounds), CGRectGetHeight(bounds) * 0.42);
    CGFloat radius = 5.5;
    [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(center.x - radius, center.y - radius,
                                                       radius * 2, radius * 2)] fill];
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(center.x - 2.5, center.y, 5, 12)
                                cornerRadius:2] fill];
}

@end

#pragma mark - Lock view controller

@interface LPLockViewController ()
// Holds every element so the unlock animation can scale them together.
@property (nonatomic, strong) UIView *contentView;
@property (nonatomic, strong) UIView *pulseView;
@property (nonatomic, strong) UIView *badgeView;
@property (nonatomic, strong) LPLockShackleView *shackleView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *messageLabel;
@property (nonatomic, strong) UIButton *unlockButton;
@property (nonatomic, assign, getter=isAuthenticating) BOOL authenticating;
@property (nonatomic, assign, getter=isUnlocking) BOOL unlocking;
@property (nonatomic, assign) BOOL hasPlayedEntrance;
// Bumped on every reset. Async work started for an earlier lock (an auth
// reply, an unlock animation) must not unlock a newer one.
@property (nonatomic, assign) NSUInteger lockGeneration;
@end

@implementation LPLockViewController

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)loadView {
    self.view = [[LPLockGradientView alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.accessibilityIdentifier = @"lock screen";

    self.contentView = [[UIView alloc] init];
    self.contentView.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.contentView];

    // Ring that pulses outward from behind the badge.
    self.pulseView = [[UIView alloc] init];
    self.pulseView.userInteractionEnabled = NO;
    self.pulseView.layer.cornerRadius = LPBadgeSize / 2;
    self.pulseView.layer.borderWidth = 2;
    self.pulseView.layer.borderColor = LPBrandMint().CGColor;
    [self.contentView addSubview:self.pulseView];

    self.badgeView = [[UIView alloc] init];
    self.badgeView.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    self.badgeView.layer.cornerRadius = LPBadgeSize / 2;
    self.badgeView.layer.borderWidth = 1;
    self.badgeView.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.15].CGColor;
    self.badgeView.isAccessibilityElement = NO;
    [self.contentView addSubview:self.badgeView];

    // 56 x 72 padlock centred in the badge. The shackle's legs run behind the
    // top of the body, so lifting it reveals a gap.
    CGFloat iconX = (LPBadgeSize - 56) / 2;
    CGFloat iconY = (LPBadgeSize - 72) / 2 - 2;
    self.shackleView = [[LPLockShackleView alloc] initWithFrame:CGRectMake(iconX + 10, iconY, 36, 38)];
    [self.badgeView addSubview:self.shackleView];
    LPLockBodyView *bodyView = [[LPLockBodyView alloc] initWithFrame:CGRectMake(iconX, iconY + 28, 56, 44)];
    [self.badgeView addSubview:bodyView];

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.text = @"LPSimpleExample is locked";
    self.titleLabel.font = [UIFont boldSystemFontOfSize:24];
    self.titleLabel.textColor = [UIColor whiteColor];
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.titleLabel.minimumScaleFactor = 0.7;
    [self.contentView addSubview:self.titleLabel];

    self.messageLabel = [[UILabel alloc] init];
    self.messageLabel.text = LPLockDefaultMessage;
    self.messageLabel.font = [UIFont systemFontOfSize:16];
    self.messageLabel.textColor = LPBrandTextMuted();
    self.messageLabel.textAlignment = NSTextAlignmentCenter;
    self.messageLabel.numberOfLines = 0;
    self.messageLabel.accessibilityIdentifier = @"lock message";
    [self.contentView addSubview:self.messageLabel];

    self.unlockButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [self.unlockButton setTitle:@"Unlock" forState:UIControlStateNormal];
    [self.unlockButton setTitleColor:LPBrandGreen() forState:UIControlStateNormal];
    [self.unlockButton setTitleColor:[LPBrandGreen() colorWithAlphaComponent:0.5]
                            forState:UIControlStateHighlighted];
    self.unlockButton.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    self.unlockButton.backgroundColor = [UIColor whiteColor];
    self.unlockButton.layer.cornerRadius = LPButtonHeight / 2;
    self.unlockButton.layer.shadowColor = [UIColor blackColor].CGColor;
    self.unlockButton.layer.shadowOpacity = 0.25;
    self.unlockButton.layer.shadowRadius = 10;
    self.unlockButton.layer.shadowOffset = CGSizeMake(0, 4);
    self.unlockButton.accessibilityLabel = @"unlock";
    [self.unlockButton addTarget:self
                          action:@selector(authenticate)
                forControlEvents:UIControlEventTouchUpInside];
    [self.contentView addSubview:self.unlockButton];

    // Repeating animations are dropped while the app is in the background.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillEnterForeground:)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.hasPlayedEntrance) {
        self.hasPlayedEntrance = YES;
        [self playEntranceAnimation];
    }
    [self startPulse];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;

    // Animated views get bounds + center rather than frame, because frame is
    // undefined while a transform is applied.
    [self place:self.contentView
         center:CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds))
           size:bounds.size];

    CGFloat width = MIN(CGRectGetWidth(bounds) - 48, 360);
    CGFloat midX = CGRectGetMidX(bounds);
    CGFloat messageHeight = ceil([self.messageLabel sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)].height);
    CGFloat titleHeight = 30;
    CGFloat totalHeight = LPBadgeSize + 32 + titleHeight + 10 + messageHeight + 36 + LPButtonHeight;
    CGFloat y = floor(CGRectGetMidY(bounds) - totalHeight / 2);

    CGSize badgeSize = CGSizeMake(LPBadgeSize, LPBadgeSize);
    CGPoint badgeCenter = CGPointMake(midX, y + LPBadgeSize / 2);
    [self place:self.pulseView center:badgeCenter size:badgeSize];
    [self place:self.badgeView center:badgeCenter size:badgeSize];
    y += LPBadgeSize + 32;

    [self place:self.titleLabel center:CGPointMake(midX, y + titleHeight / 2) size:CGSizeMake(width, titleHeight)];
    y += titleHeight + 10;

    [self place:self.messageLabel center:CGPointMake(midX, y + messageHeight / 2) size:CGSizeMake(width, messageHeight)];
    y += messageHeight + 36;

    [self place:self.unlockButton
         center:CGPointMake(midX, y + LPButtonHeight / 2)
           size:CGSizeMake(MIN(width, 280), LPButtonHeight)];
}

- (void)reset {
    // The app delegate calls this before the window is shown, so make sure
    // the subviews exist (loadViewIfNeeded is iOS 9+).
    (void)self.view;
    self.lockGeneration++;
    self.authenticating = NO;
    self.unlocking = NO;

    // Snap back to the fully visible locked state without animating: this
    // runs as the app enters the background, right before iOS takes the
    // app-switcher snapshot.
    for (UIView *view in @[self.contentView, self.badgeView, self.shackleView,
                           self.titleLabel, self.messageLabel, self.unlockButton]) {
        [view.layer removeAllAnimations];
        view.transform = CGAffineTransformIdentity;
        view.alpha = 1;
    }
    self.view.alpha = 1;
    [self setUnlockButtonEnabled:YES];
    self.messageLabel.text = LPLockDefaultMessage;
    [self.view setNeedsLayout];
    [self startPulse];
}

- (void)authenticate {
    if (self.isAuthenticating || self.isUnlocking) {
        return;
    }

    // LocalAuthentication is weak-linked because the deployment target is
    // iOS 7.1, where the framework does not exist.
    if (NSClassFromString(@"LAContext") == nil) {
        [self authenticationUnavailable:nil];
        return;
    }

    LAContext *context = [[LAContext alloc] init];
    LAPolicy policy;
    if ([self isAtLeastIOS9]) {
        // Face ID / Touch ID with the device passcode as a fallback.
        policy = LAPolicyDeviceOwnerAuthentication;
    } else {
        // iOS 8 only offers biometrics. Hide the "Enter Password" button
        // because there is no in-app password to fall back to.
        policy = LAPolicyDeviceOwnerAuthenticationWithBiometrics;
        context.localizedFallbackTitle = @"";
    }

    NSError *error = nil;
    if (![context canEvaluatePolicy:policy error:&error]) {
        [self authenticationUnavailable:error];
        return;
    }

    self.authenticating = YES;
    [self setUnlockButtonEnabled:NO];
    NSUInteger generation = self.lockGeneration;

    __weak LPLockViewController *weakSelf = self;
    [context evaluatePolicy:policy
            localizedReason:@"Unlock LPSimpleExample"
                      reply:^(BOOL success, NSError *evaluationError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            LPLockViewController *strongSelf = weakSelf;
            if (strongSelf == nil || strongSelf.lockGeneration != generation) {
                return;
            }
            strongSelf.authenticating = NO;

            if (success) {
                [strongSelf playUnlockAnimation];
            } else {
                [strongSelf setUnlockButtonEnabled:YES];
                [strongSelf showMessage:[strongSelf messageForError:evaluationError]];
                if (evaluationError.code == LAErrorAuthenticationFailed) {
                    [strongSelf playFailureAnimation];
                }
            }
        });
    }];
}

#pragma mark - Animations

- (void)playEntranceAnimation {
    NSArray *items = @[self.titleLabel, self.messageLabel, self.unlockButton];

    if (LPReduceMotionEnabled()) {
        self.contentView.alpha = 0;
        [UIView animateWithDuration:0.3 animations:^{
            self.contentView.alpha = 1;
        }];
        return;
    }

    self.badgeView.alpha = 0;
    self.badgeView.transform = CGAffineTransformMakeScale(0.6, 0.6);
    for (UIView *item in items) {
        item.alpha = 0;
        item.transform = CGAffineTransformMakeTranslation(0, 16);
    }

    [UIView animateWithDuration:0.7
                          delay:0
         usingSpringWithDamping:0.6
          initialSpringVelocity:0
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        self.badgeView.alpha = 1;
        self.badgeView.transform = CGAffineTransformIdentity;
    } completion:nil];

    [items enumerateObjectsUsingBlock:^(UIView *item, NSUInteger index, BOOL *stop) {
        [UIView animateWithDuration:0.5
                              delay:0.15 + 0.08 * index
             usingSpringWithDamping:0.85
              initialSpringVelocity:0
                            options:UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            item.alpha = 1;
            item.transform = CGAffineTransformIdentity;
        } completion:nil];
    }];
}

- (void)startPulse {
    if (self.pulseView == nil) {
        return;
    }
    [self.pulseView.layer removeAllAnimations];
    self.pulseView.transform = CGAffineTransformIdentity;

    if (LPReduceMotionEnabled()) {
        self.pulseView.alpha = 0;
        return;
    }

    self.pulseView.alpha = 0.7;
    [UIView animateWithDuration:2.0
                          delay:0
                        options:(UIViewAnimationOptionRepeat |
                                 UIViewAnimationOptionCurveEaseOut |
                                 UIViewAnimationOptionAllowUserInteraction)
                     animations:^{
        self.pulseView.transform = CGAffineTransformMakeScale(1.45, 1.45);
        self.pulseView.alpha = 0;
    } completion:nil];
}

- (void)playFailureAnimation {
    if (LPReduceMotionEnabled()) {
        return;
    }
    NSArray *offsets = @[@-14, @12, @-8, @5, @0];
    [UIView animateKeyframesWithDuration:0.45
                                   delay:0
                                 options:UIViewKeyframeAnimationOptionAllowUserInteraction
                              animations:^{
        [offsets enumerateObjectsUsingBlock:^(NSNumber *offset, NSUInteger index, BOOL *stop) {
            [UIView addKeyframeWithRelativeStartTime:index / (double)offsets.count
                                    relativeDuration:1.0 / offsets.count
                                          animations:^{
                self.badgeView.transform = CGAffineTransformMakeTranslation(offset.doubleValue, 0);
            }];
        }];
    } completion:nil];
}

// Lifts the shackle, then fades the lock away before telling the delegate.
- (void)playUnlockAnimation {
    self.unlocking = YES;
    [self setUnlockButtonEnabled:NO];
    NSUInteger generation = self.lockGeneration;

    __weak LPLockViewController *weakSelf = self;
    void (^finish)(BOOL) = ^(BOOL finished) {
        LPLockViewController *strongSelf = weakSelf;
        // A reset (the app was locked again mid-animation) cancels the unlock.
        if (strongSelf == nil || strongSelf.lockGeneration != generation) {
            return;
        }
        strongSelf.unlocking = NO;
        [strongSelf.pulseView.layer removeAllAnimations];
        [strongSelf.delegate lockViewControllerDidUnlock:strongSelf];
    };

    if (LPReduceMotionEnabled()) {
        [UIView animateWithDuration:0.25 animations:^{
            self.view.alpha = 0;
        } completion:finish];
        return;
    }

    [UIView animateWithDuration:0.35
                          delay:0
         usingSpringWithDamping:0.5
          initialSpringVelocity:0
                        options:0
                     animations:^{
        self.shackleView.transform = CGAffineTransformMakeTranslation(0, -10);
        self.pulseView.alpha = 0;
    } completion:^(BOOL finished) {
        if (weakSelf.lockGeneration != generation) {
            return;
        }
        [UIView animateWithDuration:0.3
                              delay:0.1
                            options:UIViewAnimationOptionCurveEaseIn
                         animations:^{
            weakSelf.contentView.transform = CGAffineTransformMakeScale(1.08, 1.08);
            weakSelf.view.alpha = 0;
        } completion:finish];
    }];
}

#pragma mark - Private

- (void)applicationWillEnterForeground:(NSNotification *)notification {
    if (self.isViewLoaded && !self.isUnlocking) {
        [self startPulse];
    }
}

- (void)place:(UIView *)view center:(CGPoint)center size:(CGSize)size {
    view.bounds = CGRectMake(0, 0, size.width, size.height);
    view.center = center;
}

- (void)setUnlockButtonEnabled:(BOOL)enabled {
    self.unlockButton.enabled = enabled;
    self.unlockButton.alpha = enabled ? 1 : 0.6;
}

- (void)authenticationUnavailable:(NSError *)error {
#if DEBUG
    // Simulators and test devices usually have no passcode set. Let Debug
    // builds (the ones Calabash drives) through so UI tests keep working.
    // Release builds stay locked. No unlock animation here, so tests aren't
    // slowed down.
    NSLog(@"LPLockViewController: device authentication unavailable (%@); "
          @"skipping the lock in this DEBUG build.",
          error.localizedDescription ?: @"LocalAuthentication not available");
    [self.delegate lockViewControllerDidUnlock:self];
#else
    if (error == nil) {
        [self showMessage:@"This app requires iOS 8 or later with a device passcode."];
    } else if (error.code == LAErrorPasscodeNotSet) {
        [self showMessage:@"Set a device passcode in Settings to use this app."];
    } else {
        [self showMessage:@"This device can't verify your identity, so the app stays locked."];
    }
#endif
}

- (NSString *)messageForError:(NSError *)error {
    switch (error.code) {
        case LAErrorUserCancel:
        case LAErrorSystemCancel:
        case LAErrorAppCancel:
            return LPLockDefaultMessage;
        case LAErrorAuthenticationFailed:
            return @"Couldn't verify your identity. Try again.";
        default:
            return @"Authentication didn't complete. Try again.";
    }
}

- (void)showMessage:(NSString *)message {
    if ([self.messageLabel.text isEqualToString:message]) {
        return;
    }
    [UIView transitionWithView:self.messageLabel
                      duration:0.25
                       options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{
        self.messageLabel.text = message;
    } completion:nil];
    [self.view setNeedsLayout];
}

- (BOOL)isAtLeastIOS9 {
    NSProcessInfo *processInfo = [NSProcessInfo processInfo];
    if (![processInfo respondsToSelector:@selector(isOperatingSystemAtLeastVersion:)]) {
        return NO;
    }
    NSOperatingSystemVersion iOS9 = {9, 0, 0};
    return [processInfo isOperatingSystemAtLeastVersion:iOS9];
}

@end
