#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>
#import <dlfcn.h>
typedef CFTypeRef IOHIDEventRef;
extern IOHIDEventRef IOHIDEventCreate(CFAllocatorRef, uint32_t type, uint64_t ts, uint32_t options);
extern void IOHIDEventSetIntegerValue(IOHIDEventRef, uint32_t field, CFIndex v);
extern void IOHIDEventSetFloatValue(IOHIDEventRef, uint32_t field, double v);
extern double IOHIDEventGetFloatValue(IOHIDEventRef, uint32_t field);
extern CFIndex IOHIDEventGetIntegerValue(IOHIDEventRef, uint32_t field);
extern void IOHIDEventAppendEvent(IOHIDEventRef, IOHIDEventRef, uint32_t);
extern uint32_t IOHIDEventGetType(IOHIDEventRef);
extern IOHIDEventRef CGEventCopyIOHIDEvent(CGEventRef);
int main(void) {
  printf("AX trusted: %d\n", AXIsProcessTrusted());
  void *sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW);
  void (*setHID)(CGEventRef, IOHIDEventRef) = dlsym(sl, "SLEventSetIOHIDEvent");
  printf("SkyLight %p SLEventSetIOHIDEvent %p CGSGetActiveSpace %p CGSMainConnectionID %p\n", sl, setHID, dlsym(sl,"CGSGetActiveSpace"), dlsym(sl,"CGSMainConnectionID"));
  IOHIDEventRef h = IOHIDEventCreate(NULL, 23, 0, 1u<<24);
  IOHIDEventSetIntegerValue(h, (23<<16)|1, 1);
  IOHIDEventSetIntegerValue(h, (23<<16)|5, 3);
  IOHIDEventSetFloatValue(h, (23<<16)|2, 0.25);
  CGEventRef e = CGEventCreate(NULL); CGEventSetType(e, 30);
  if (setHID) setHID(e, h);
  IOHIDEventRef back = CGEventCopyIOHIDEvent(e);
  if (back) printf("roundtrip type=%u motion=%ld flavor=%ld progress=%f same=%d\n", IOHIDEventGetType(back), IOHIDEventGetIntegerValue(back,(23<<16)|1), IOHIDEventGetIntegerValue(back,(23<<16)|5), IOHIDEventGetFloatValue(back,(23<<16)|2), back==h);
  else printf("no hid event attached\n");
  NSLog(@"%@", (__bridge id)h);
  printf("natural scroll: %s\n", [[[NSUserDefaults standardUserDefaults] objectForKey:@"com.apple.swipescrolldirection"] description].UTF8String);
  int (*conn)(void) = dlsym(sl,"CGSMainConnectionID"); uint64_t (*act)(int) = dlsym(sl,"CGSGetActiveSpace");
  CFArrayRef (*spaces)(int) = dlsym(sl,"CGSCopyManagedDisplaySpaces");
  if (conn && act) printf("active space %llu\n", act(conn()));
  if (spaces) { NSArray *a = CFBridgingRelease(spaces(conn())); for (NSDictionary *d in a) printf("display spaces: %lu\n", [d[@"Spaces"] count]); }
  return 0;
}
