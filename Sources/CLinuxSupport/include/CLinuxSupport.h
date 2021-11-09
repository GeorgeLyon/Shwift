
#ifndef __CLINUXSUPPORT_H
#define __CLINUXSUPPORT_H

#ifdef __linux__

#include <stdbool.h>
#include <stdint.h>
#include <unistd.h>

// MARK: - Building an Invocation

typedef struct ShwiftSpawnInvocation ShwiftSpawnInvocation;

/**
 Create a `ShwiftSpawnInvocation`.
 
 If non-NULL, the caller is responsible for eventually destroying the returned value via `ShwiftSpawnInvocationDestroy`.
 */
ShwiftSpawnInvocation* ShwiftSpawnInvocationCreate(
  const char* executablePath,
  const char* workingDirectory,
  int argumentCapacity,
  int environmentCapacity,
  int fileDescriptorMappingsCapacity
);

/**
 Destroys a `ShwiftSpawnInvocation`.
 */
void ShwiftSpawnInvocationDestroy(ShwiftSpawnInvocation*);

/**
 Adds an argument to this context.

 This function creates a copy of the argument, so the caller can safely free it once this function returns.
 */
void ShwiftSpawnInvocationAddArgument(ShwiftSpawnInvocation*, const char*);

/**
 Adds an environment entry, must be of the form "key=value".

 This function creates a copy of the entry, so the caller can safely free it once this function returns.
 */
void ShwiftSpawnInvocationAddEnvironmentEntry(ShwiftSpawnInvocation*, const char*);

/**
 Specifies that this context should map the existing file descriptor specified by `source` should be mapped to `target` in the spawned process. 
 This function duplicates `source`, so the caller can safely close it after this function returns.
 */
void ShwiftSpawnInvocationAddFileDescriptorMapping(
  ShwiftSpawnInvocation*,
  int source,
  int target);

// MARK: - Determining the outcome of an invocation

/**
 A structure which describes how a spawn invocation failed.
 */
typedef struct {
  /// The file where the error ocurred
  const char *file;

  /// The line at which a failure occured.
  intptr_t line;

  /// The return value of the function that caused the failure
  intptr_t returnValue;

  /// The value of `errno` after the failure was encountered
  int errorNumber;
} ShwiftSpawnInvocationFailure;

/**
 Retrieves information about the outcome of a spawn operation. This should only be called once the invocation is "complete", which is only the case once the `monitor` passed to `ShwiftSpawnInvocationLaunch` has been closed. Attepmting to access this prior to the context being "complete" will cause an error.

 - Returns: If the invocation succeeded at launching the child process, returns `true` (and `failure` is not mutated). If the invocation failed to launch the child process, returns `false` and writes information about the failure to `failure`.
 */
bool ShwiftSpawnInvocationComplete(ShwiftSpawnInvocation*, ShwiftSpawnInvocationFailure* failure);

// MARK: - Spawn

/**
 Launches a child process with according to the provided invocation.

 - Parameters:
  - invocation: An object representing the invocation. An invocation object may only be launched once.
  - monitor: A file descriptor which will be duplicated and the duplicate will be closed when `invocation` is "complete".
- Returns: The process ID of thes spawned process, or -1. If a process ID is returned, it is the caller's responsibility to eventually `wait` on the returned ID.
 */
pid_t ShwiftSpawnInvocationLaunch(
  ShwiftSpawnInvocation* invocation,
  int monitor
);

#endif // __linux__

#endif // __CLINUXSUPPORT_H
