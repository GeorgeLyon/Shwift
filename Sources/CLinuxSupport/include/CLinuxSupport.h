
#ifndef __CLINUXSUPPORT_H
#define __CLINUXSUPPORT_H

#ifdef __linux__

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <stdbool.h>
#include <stdint.h>
#include <sched.h>

/**
 A structure which gives more concrete information about the outcome of a call to `shwiftSpawn`. 
 */
typedef struct {
  /**
   if `true`, the operation succeeded in launching the requested executable and the `success` property of `payload` is valid. If `false`, launching the requested executable failed and the `failure` property of `payload` contains information about the first failure that occured.
   */
  bool isSuccess;
  
  union {
    struct {

    } success;
    struct {
      /// The line at which a failure occured.
      intptr_t line;

      /// The return value of the function that caused the failure
      intptr_t returnValue;

      /// The value of `errno` after the failure was encountered
      int error;
    } failure;
  } payload;
} ShwiftSpawnOutcome;

typedef struct ShwiftSpawnContext ShwiftSpawnContext;

/**
 Create a `ShwiftSpawnContext`. 
 
 If non-NULL, the caller is responsible for eventually destroying the returned value via `ShwiftSpawnContextDestroy`.
 */
ShwiftSpawnContext* ShwiftSpawnContextCreate(
  const char* executablePath,
  const char* workingDirectory,
  int argumentCapacity,
  int environmentCapacity,
  int fileDescriptorMappingsCapacity
);

/**
 Destroys a `ShwiftSpawnContext`.
 */
void ShwiftSpawnContextDestroy(ShwiftSpawnContext*);

/**
 Adds an argument to this context.

 This function creates a copy of the argument, so the caller can safely free it once this function returns.
 */
void ShwiftSpawnContextAddArgument(ShwiftSpawnContext*, const char*);

/**
 Adds an environment entry, must be of the form "key=value".

 This function creates a copy of the entry, so the caller can safely free it once this function returns.
 */
void ShwiftSpawnContextAddEnvironmentEntry(ShwiftSpawnContext*, const char*);

/**
 Specifies that this context should map the existing file descriptor specified by `source` should be mapped to `target` in the spawned process. 
 This function duplicates `source`, so the caller can safely close it after this function returns.
 */
void ShwiftSpawnContextAddFileDescriptorMapping(
  ShwiftSpawnContext*,
  int source,
  int target);

/**
 Retrieves information about the outcome of `ShiwftSpawn` from a `ShwiftSpawnContext`. This should only be called once the context is "complete", which is only the case once `ShwiftSpawn` has closed the `monitor` file descriptor. Attepmting to access this prior to the context being "complete" results in undefined behavior.
 */
ShwiftSpawnOutcome ShwiftSpawnContextGetOutcome(ShwiftSpawnContext*);

/**
 Spawns a child process with the specified parameters.

 - Parameters:
  - context: A context which will be used to access concrete information about the outcome of `ShwiftSpawn`.
  - monitor: A file descriptor which will be duplicated and the duplicate will be closed when `context` is "complete".
- Returns: The process ID of thes spawned process, or -1. If a process ID is returned, it is the caller's responsibility to eventually `wait` on the returned ID.
 */
pid_t ShwiftSpawn(
  ShwiftSpawnContext* context,
  int monitor
);

#endif // __linux__

#endif // __CLINUXSUPPORT_H
