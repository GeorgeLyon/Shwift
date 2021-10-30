
#ifdef __linux__

/// A non-variadic `clone` which can be imported into Swift
int shwift_clone(int (*fn)(void *), void *stack, int flags, void *arg);

#endif
