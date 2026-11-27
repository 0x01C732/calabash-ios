//
//  LPLockViewController.m
//  LPSimpleExample
//

#import "LPLockViewController.h"
#import <LocalAuthentication/LocalAuthentication.h>

static NSString *const LPLockDefaultMessage = @"Unlock to continue.";

@interface LPLockViewController ()
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *messageLabel;
@property (nonatomic, strong) UIButton *unlockButton;
@property (nonatomic, assign, getter=isAuthenticating) BOOL authenticating;
@end

@implementation LPLockViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];
    self.view.accessibilityIdentifier = @"lock screen";

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.text = @"LPSimpleExample is locked";
    self.titleLabel.font = [UIFont boldSystemFontOfSize:22];
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    [self.view addSubview:self.titleLabel];

    self.messageLabel = [[UILabel alloc] init];
    self.messageLabel.text = LPLockDefaultMessage;
    self.messageLabel.textColor = [UIColor darkGrayColor];
    self.messageLabel.textAlignment = NSTextAlignmentCenter;
    self.messageLabel.numberOfLines = 0;
    self.messageLabel.accessibilityIdentifier = @"lock message";
    [self.view addSubview:self.messageLabel];

    self.unlockButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.unlockButton setTitle:@"Unlock" forState:UIControlStateNormal];
    self.unlockButton.titleLabel.font = [UIFont systemFontOfSize:20];
    self.unlockButton.accessibilityLabel = @"unlock";
    [self.unlockButton addTarget:self
                          action:@selector(authenticate)
                forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.unlockButton];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    CGFloat width = MIN(CGRectGetWidth(bounds) - 40, 400);
    CGFloat x = (CGRectGetWidth(bounds) - width) / 2;
    CGFloat midY = CGRectGetMidY(bounds);

    self.titleLabel.frame = CGRectMake(x, midY - 80, width, 30);
    CGSize messageSize = [self.messageLabel sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)];
    self.messageLabel.frame = CGRectMake(x, midY - 40, width, messageSize.height);
    self.unlockButton.frame = CGRectMake(x, CGRectGetMaxY(self.messageLabel.frame) + 20, width, 44);
}

- (void)reset {
    [self showMessage:LPLockDefaultMessage];
}

- (void)authenticate {
    if (self.isAuthenticating) {
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
    self.unlockButton.enabled = NO;

    __weak LPLockViewController *weakSelf = self;
    [context evaluatePolicy:policy
            localizedReason:@"Unlock LPSimpleExample"
                      reply:^(BOOL success, NSError *evaluationError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            LPLockViewController *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            strongSelf.authenticating = NO;
            strongSelf.unlockButton.enabled = YES;

            if (success) {
                [strongSelf.delegate lockViewControllerDidUnlock:strongSelf];
            } else {
                [strongSelf showMessage:[strongSelf messageForError:evaluationError]];
            }
        });
    }];
}

#pragma mark - Private

- (void)authenticationUnavailable:(NSError *)error {
#if DEBUG
    // Simulators and test devices usually have no passcode set. Let Debug
    // builds (the ones Calabash drives) through so UI tests keep working.
    // Release builds stay locked.
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
    self.messageLabel.text = message;
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
