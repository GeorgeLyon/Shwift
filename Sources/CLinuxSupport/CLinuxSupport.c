
#ifdef __linux__

#include <CLinuxSupport.h>

#define _GNU_SOURCE
#include <sched.h>

int shwift_clone(int (*fn)(void *), void *stack, int flags, void *arg) {
  return clone(fn, stack, flags, arg);
}

#endif
