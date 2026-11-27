//
//  LPLockViewController.h
//  LPSimpleExample
//
//  Full-screen lock that hides the app's content until the device owner
//  authenticates with Face ID / Touch ID or the device passcode.
//

#import <UIKit/UIKit.h>

@class LPLockViewController;

@protocol LPLockViewControllerDelegate <NSObject>
- (void)lockViewControllerDidUnlock:(LPLockViewController *)controller;
@end

@interface LPLockViewController : UIViewController

@property (nonatomic, weak) id<LPLockViewControllerDelegate> delegate;

// Shows the system authentication prompt. Does nothing if one is already up.
- (void)authenticate;

// Restores the initial "locked" message. Call when the app is locked again.
- (void)reset;

@end
