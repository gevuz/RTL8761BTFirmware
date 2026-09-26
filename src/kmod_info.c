// SPDX-License-Identifier: GPL-2.0-or-later
//
// Equivalent of the file Xcode generates for every kext: identifies the kext to the kernel
// and hooks up the C++ constructors (_start/_stop come from libkmodc++).
#include <mach/mach_types.h>

extern kern_return_t _start(kmod_info_t *ki, void *data);
extern kern_return_t _stop(kmod_info_t *ki, void *data);

__attribute__((visibility("default"))) KMOD_EXPLICIT_DECL(BUNDLE_ID, BUNDLE_VERSION, _start, _stop)
__private_extern__ kmod_start_func_t *_realmain = 0;
__private_extern__ kmod_stop_func_t *_antimain = 0;
__private_extern__ int _kext_apple_cc = __APPLE_CC__;
