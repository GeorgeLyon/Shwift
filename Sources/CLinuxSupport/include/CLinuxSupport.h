
#ifdef __linux__

#define _GNU_SOURCE
#include <stdbool.h>
#include <stdint.h>
#include <sched.h>

typedef struct {
  int32_t source, target;
} file_descriptor_mapping_t;

typedef struct {
  /// Path of the executable to spawn
  const char *executablePath;

  /// `NULL`-terminated arguments array
  char *const *arguments;

  /// `NULL`-terminated environment variables array ("key=value")
  char *const *environment;

  /// Directory to run the program in
  const char *directory;

  /**
   Mapping of file descriptors to pass to the child process. All descriptors that are not specified as targets here will be closed.
   */
  int32_t file_descriptor_mapping_count;
  file_descriptor_mapping_t* file_descriptor_mapping;

  /// This structure will be populated based on the results of `clone`
  struct {
    bool succeeded;

    /// If we didn't succeed, the line in `shwift_spawn.c` that caused the failure
    uint32_t line;

    /// If applicable, the return value of the function causing `shwift_spawn` to terminate
    uintptr_t return_value;

    /// If applicable, the value of `errno` when `shwift_spawn` failed
    int error;

    /// Set to the process id of the launched proces
    pid_t pid;
  } outcome;
} shwift_spawn_parameters_t;

/**
 A variant of `posix_spawn` which uses `clone`/`execve` to avoid race conditions when emulating `POSIX_SPAWN_CLOEXEC_DEFAULT`.

 - Parameters:
  - parameters: Must be a pointer to **shared** memory. If `parameters->outcome.pid` is nonzero after this returns it must be waited on with the __WALL flag. 
 */
void shwift_spawn(shwift_spawn_parameters_t* parameters);

#endif
