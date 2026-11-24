#import "TouchInjector.h"
#import <UIKit/UIKit.h>
#import <mach/mach_time.h>
#import <unistd.h>
#import <dlfcn.h>

// IOHIDEvent 私有接口：运行期 dlsym，拿不到就返回 NO
typedef void *IOHIDEventSystemClientRef;
typedef void *IOHIDEventRef;

typedef IOHIDEventSystemClientRef (*SMClientCreateFn)(CFAllocatorRef);
typedef IOHIDEventSystemClientRef (*SMClientCreateTypeFn)(CFAllocatorRef, int, CFDictionaryRef);
typedef void (*SMDispatchFn)(IOHIDEventSystemClientRef, IOHIDEventRef);
typedef IOHIDEventRef (*SMCreateDigitizerFn)(CFAllocatorRef, AbsoluteTime, uint32_t, uint32_t,
                                            uint32_t, uint32_t, uint32_t, double, double,
                                            double, double, double, Boolean, Boolean, CFOptionFlags);
typedef void (*SMSetIntFn)(IOHIDEventRef, int32_t, int32_t);

static IOHIDEventSystemClientRef gClient = NULL;
static SMClientCreateFn fnCreate = NULL;
static SMClientCreateTypeFn fnCreateType = NULL;
static SMDispatchFn fnDispatch = NULL;
static SMCreateDigitizerFn fnDigitizer = NULL;
static SMSetIntFn fnSetInt = NULL;
static Boolean gLoaded = false;
static Boolean gLoadOk = false;

enum { kSMIsDisplayIntegrated = 0x000B0008 };
static int gVariant = 0;   // 当前注入参数组合（自检会把它试出来）

static void SMLoad(void) {
    if (gLoaded) return;
    gLoaded = true;
    void *h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    if (!h) h = dlopen("/usr/lib/libIOKit.dylib", RTLD_LAZY);
    void *probe = h ? dlsym(h, "IOHIDEventSystemClientCreate") : NULL;
    if (!probe) probe = dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
    if (!probe) { gLoadOk = false; return; }
    #define SM_SYM(name) (h ? dlsym(h, name) : NULL) ?: dlsym(RTLD_DEFAULT, name)
    fnCreate = (SMClientCreateFn)SM_SYM("IOHIDEventSystemClientCreate");
    fnCreateType = (SMClientCreateTypeFn)SM_SYM("IOHIDEventSystemClientCreateWithType");
    fnDispatch = (SMDispatchFn)SM_SYM("IOHIDEventSystemClientDispatchEvent");
    fnDigitizer = (SMCreateDigitizerFn)SM_SYM("IOHIDEventCreateDigitizerEvent");
    fnSetInt = (SMSetIntFn)SM_SYM("IOHIDEventSetIntegerValue");
    #undef SM_SYM
    gLoadOk = (fnCreate && fnDispatch && fnDigitizer && fnSetInt);
}

static AbsoluteTime SMTimeNow(void) {
    uint64_t t = mach_absolute_time();
    AbsoluteTime at;
    at.lo = (UInt32)(t & 0xFFFFFFFFULL);
    at.hi = (SInt32)(t >> 32);
    return at;
}

@implementation SMTouchInjector

+ (void)setVariant:(NSInteger)v { gVariant = (int)v; }
+ (NSInteger)variant { return gVariant; }

+ (IOHIDEventSystemClientRef)client {
    SMLoad();
    if (!gLoadOk) return NULL;
    if (!gClient) {
        if (fnCreateType) gClient = fnCreateType(kCFAllocatorDefault, 1, NULL);
        if (!gClient) gClient = fnCreate(kCFAllocatorDefault);
    }
    return gClient;
}

+ (BOOL)dispatchTouchAt:(CGPoint)p phaseDown:(BOOL)down {
    IOHIDEventSystemClientRef client = [self client];
    if (!client) return NO;

    uint32_t type;
    uint32_t mask;
    Boolean range;
    Boolean touch;
    switch (gVariant % 4) {
        case 0: type = 3; mask = down ? 0x01 : 0x02; range = down ? 1 : 0; touch = down ? 1 : 0; break; // hand + 事件掩码
        case 1: type = 1; mask = 0;                  range = down ? 1 : 0; touch = 1;            break; // hand + 无掩码
        case 2: type = 2; mask = down ? 0x01 : 0x02; range = down ? 1 : 0; touch = down ? 1 : 0; break; // finger + 掩码
        default:type = 2; mask = 0;                  range = down ? 1 : 0; touch = 1;            break; // finger + 无掩码
    }

    IOHIDEventRef event = fnDigitizer(kCFAllocatorDefault, SMTimeNow(), type,
                                      0, 1, mask, 0,
                                      p.x, p.y, 0, 0, 0,
                                      range, touch, 0);
    if (!event) return NO;
    fnSetInt(event, kSMIsDisplayIntegrated, 1);
    fnDispatch(client, event);
    CFRelease(event);
    return YES;
}

+ (BOOL)isAvailable {
    if (![self client]) return NO;
    return [self dispatchTouchAt:CGPointMake(1, 1) phaseDown:YES] &&
           [self dispatchTouchAt:CGPointMake(1, 1) phaseDown:NO];
}

+ (CGSize)screenSizeInPoints {
    CGRect r = [UIScreen mainScreen].bounds;
    return CGSizeMake(r.size.width, r.size.height);
}

+ (CGSize)screenSizeInPixels {
    CGRect r = [UIScreen mainScreen].bounds;
    CGFloat s = [UIScreen mainScreen].scale;
    return CGSizeMake(r.size.width * s, r.size.height * s);
}

+ (BOOL)tapAt:(CGPoint)point {
    BOOL ok = [self dispatchTouchAt:point phaseDown:YES];
    usleep(60000);
    ok = [self dispatchTouchAt:point phaseDown:NO] && ok;
    return ok;
}

+ (BOOL)longPressAt:(CGPoint)point duration:(NSTimeInterval)seconds {
    BOOL ok = [self dispatchTouchAt:point phaseDown:YES];
    usleep((useconds_t)(MAX(0.05, seconds) * 1000000));
    ok = [self dispatchTouchAt:point phaseDown:NO] && ok;
    return ok;
}

+ (BOOL)swipeFrom:(CGPoint)from to:(CGPoint)to duration:(NSTimeInterval)seconds {
    const int steps = 18;
    BOOL ok = [self dispatchTouchAt:from phaseDown:YES];
    useconds_t gap = (useconds_t)(MAX(0.05, seconds) * 1000000 / steps);
    for (int i = 1; i <= steps; i++) {
        CGFloat t = (CGFloat)i / steps;
        CGPoint p = CGPointMake(from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t);
        ok = [self dispatchTouchAt:p phaseDown:YES] && ok;
        usleep(gap);
    }
    ok = [self dispatchTouchAt:to phaseDown:NO] && ok;
    return ok;
}


+ (BOOL)swipeFrom:(CGPoint)from to:(CGPoint)to duration:(NSTimeInterval)seconds hold:(NSTimeInterval)holdSeconds {
    const int steps = 18;
    BOOL ok = [self dispatchTouchAt:from phaseDown:YES];
    useconds_t gap = (useconds_t)(MAX(0.05, seconds) * 1000000 / steps);
    for (int i = 1; i <= steps; i++) {
        CGFloat t = (CGFloat)i / steps;
        CGPoint p = CGPointMake(from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t);
        ok = [self dispatchTouchAt:p phaseDown:YES] && ok;
        usleep(gap);
    }
    if (holdSeconds > 0) usleep((useconds_t)(holdSeconds * 1000000));
    ok = [self dispatchTouchAt:to phaseDown:NO] && ok;
    return ok;
}
@end
