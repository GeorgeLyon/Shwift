
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
 Represents the mapping of a file descriptor from `source` to `target`. `source` and `target` may be the same, indicating that a file descriptor should be passed to the child process as-is.
 */
typedef struct {
  int source, target;
} ShwiftSpawnFileDescriptorMapping;

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
 Create a `ShwiftSpawnContext`. If non-NULL, the caller is responsible for eventually destroying the returned value via `ShwiftSpawnContextDestroy`.
 */
ShwiftSpawnContext* ShwiftSpawnContextCreate();

/**
 Destroys a `ShwiftSpawnContext`.

 - Returns: `false` if something went wrong.
 */
bool ShwiftSpawnContextDestroy(ShwiftSpawnContext*);

/**
 Retrieves information about the outcome of `ShiwftSpawn` from a `ShwiftSpawnContext`. This should only be called once the context is "ready", which is only the case once `ShwiftSpawn` has closed the `monitor` file descriptor. Attepmting to access this prior to the context being "ready" results in undefined behavior.
 */
ShwiftSpawnOutcome ShwiftSpawnContextGetOutcome(ShwiftSpawnContext*);

/**
 Spawns a child process with the specified parameters.

 - Parameters:
  - executablePath: The path to the executable
  - arguments: A NULL-terminated list of arguments
  - workingDirectory: The directory to launch the executable in
  - environment: A NULL-terminated list of environment entires (should be of the form "key=value")
  - fileDescriptorMappingsCount: The number of file descriptor mappings passed as `fileDescriptorMappings`
  - fileDescriptorMappings: File descriptors to map into the child process. Only descriptors which are specified as the `target` of a mapping will be inherited by the child process, all other descriptors will be closed (similar to the behavior of POSIX_SPAWN_CLOEXEC_DEFAULT).
  - context: A context which will be used to access concrete information about the outcome of `ShwiftSpawn`. A particular context should only be passed to `ShwiftSpawn` once. 
  - monitor: An open file descriptor which will be closed once `context` is "ready" (see `ShwiftSpawnContextGetOutcome`).
- Returns: The process ID of thes spawned process, or -1. If a process ID is returned, it is the caller's responsibility to eventually `wait` on the returned ID.
 */
pid_t ShwiftSpawn(
  const char* executablePath,
  char* const* arguments,
  const char* workingDirectory,
  char* const* environment,
  int fileDescriptorMappingsCount,
  const ShwiftSpawnFileDescriptorMapping* fileDescriptorMappings,
  ShwiftSpawnContext* context,
  int monitor
);

#endif // __linux__

#endif // __CLINUXSUPPORT_H
