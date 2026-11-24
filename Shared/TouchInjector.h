#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 触摸注入（IOHIDEvent 私有事件派发）
/// 说明：能否成功取决于签名时授予的 entitlements（com.apple.private.hid.client.event-dispatch /
/// platform-application）。越狱或 TrollStore 签名的包一定可用；普通个人证书通常不可用 —— 这种情况
/// 会返回 NO，客户端自动回落到 WDA 触控通道。
@interface SMTouchInjector : NSObject

+ (BOOL)isAvailable;
+ (void)setVariant:(NSInteger)v;
+ (NSInteger)variant;

/// 屏幕点尺寸（points）——iOS 触摸事件用的就是这个坐标系
+ (CGSize)screenSizeInPoints;
+ (CGSize)screenSizeInPixels;

+ (BOOL)tapAt:(CGPoint)point;
+ (BOOL)longPressAt:(CGPoint)point duration:(NSTimeInterval)seconds;
+ (BOOL)swipeFrom:(CGPoint)from to:(CGPoint)to duration:(NSTimeInterval)seconds;
+ (BOOL)swipeFrom:(CGPoint)from to:(CGPoint)to duration:(NSTimeInterval)seconds hold:(NSTimeInterval)holdSeconds;

@end

NS_ASSUME_NONNULL_END
