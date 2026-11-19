// Declarations for the IOHIDEvent functions IOKit exports but does not publish headers for.
// The event layout is documented in Apple's open-source IOHIDFamily (IOHIDEventTypes.h).
#ifndef CHIDEVENT_H
#define CHIDEVENT_H
#include <CoreFoundation/CoreFoundation.h>

CF_ASSUME_NONNULL_BEGIN

CFTypeRef IOHIDEventCreate(CFAllocatorRef _Nullable allocator, uint32_t type, uint64_t timestamp, uint32_t options) CF_RETURNS_RETAINED;
void IOHIDEventSetIntegerValue(CFTypeRef event, uint32_t field, CFIndex value);
void IOHIDEventSetFloatValue(CFTypeRef event, uint32_t field, double value);
void IOHIDEventAppendEvent(CFTypeRef parent, CFTypeRef child, uint32_t options);
CF_ASSUME_NONNULL_END

#endif
