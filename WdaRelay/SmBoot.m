#import <Foundation/Foundation.h>

extern void sm_relay_entry(void);

__attribute__((constructor))
static void sm_relay_boot(void) {
    sm_relay_entry();
}
