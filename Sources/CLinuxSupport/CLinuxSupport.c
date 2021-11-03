
#ifdef __linux__

#include <CLinuxSupport.h>

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

/**
 Shared memory is scary... add some `volatile` keywords to make sure the compiler doesn't try to be too clever.
 */
typedef struct {
  shwift_spawn_parameters_t volatile* volatile p;
} shared_parameter_wrapper_t;

/**
 - Warning: Printing from this file is dangerous because we may have already mapped `stdout` to a different file descriptor.
 */
// #include <stdio.h>

#define CHECK(expr, expectation) \
  ({  \
    errno = 0; \
    typeof(expr) return_value = ({ expr; }); \
    if ((!({ return_value expectation; })) || (errno != 0)) { \
      wrapper->p->outcome.error = errno; \
      wrapper->p->outcome.return_value = (uintptr_t)return_value; \
      wrapper->p->outcome.line = __LINE__; \
      wrapper->p->outcome.succeeded = false; \
      exit(1); \
    } \
    return_value; \
  })

static int child_fn(void* arg) {
  shared_parameter_wrapper_t *wrapper = (shared_parameter_wrapper_t *)arg;

  /// Create new temporaries for each mapped descriptor that do not correspond to one of the target file descriptors.
  for (int i = 0; i < wrapper->p->file_descriptor_mapping_count; i++) {
    while (true) {
      int temporary = CHECK(dup(wrapper->p->file_descriptor_mapping[i].source), != -1);
      bool isTarget = false;
      for (int i = 0; i < wrapper->p->file_descriptor_mapping_count; i++) {
        if (temporary == wrapper->p->file_descriptor_mapping[i].target) {
          isTarget = true;
          break;
        }
      }
      if (!isTarget) {
        /// Modifications should not affect the parent process because this array should not be in shared memory.
        wrapper->p->file_descriptor_mapping[i].source = temporary;
        break;
      }
    }
  }
  /// Close all open file descriptors except the new temporaries.
  int directory_descriptor = CHECK(open("/proc/self/fd", O_RDONLY | O_DIRECTORY), != -1);
  DIR* directory = CHECK(fdopendir(directory_descriptor), != NULL);
  struct dirent *entry;
  /// We use `== return_value` to have the first condition always be true. Failure is communicated via `errno` being != 0
  while (( entry = CHECK(readdir(directory), == return_value) )) {
    /**
     - note: The `d_name` field is explicitly guaranteed to be a NUL-terminated string, indeed the `readdir` notes imply that null-termination is the only thing we can depend on. As such we can use unbounded string functions with this value that we would otherwise avoid (i.e. `strcmp` vs `strncmp`).
     */
    /// Skip known non-descriptor entries
    if (strcmp(entry->d_name, ".") == 0) {
      continue;
    }
    if (strcmp(entry->d_name, "..") == 0) {
      continue;
    }

    char *endptr;
    int descriptor = (int)CHECK(strtol(entry->d_name, &endptr, 10), < INT_MAX);
    CHECK(*endptr, == '\0');
    /// Skip the directory descriptor
    if (descriptor == directory_descriptor) {
      continue;
    }
    /// Skip newly-created temporaries
    bool isTemporary = false;
    for (int i = 0; i < wrapper->p->file_descriptor_mapping_count; i++) {
      if (descriptor == wrapper->p->file_descriptor_mapping[i].source) {
        isTemporary = true;
        break;
      }
    }
    if (isTemporary) {
      continue;
    }
    CHECK(close(descriptor), == 0);
  }
  /// We can't use CHECK with readdir because `NULL` is used to signify both the end of the list and failure.
  CHECK(closedir(directory), == 0);
  /// Copy and close temporaries
  for (int i = 0; i < wrapper->p->file_descriptor_mapping_count; i++) {
    int source = wrapper->p->file_descriptor_mapping[i].source;
    int target = wrapper->p->file_descriptor_mapping[i].target;
    CHECK(dup2(source, target), == target);
    CHECK(close(source), == 0);
  }

  CHECK(chdir(wrapper->p->directory), == 0);

  /// This will be unset if `execve` fails
  wrapper->p->outcome.succeeded = true;
  CHECK(
    execve(wrapper->p->executablePath, wrapper->p->arguments, wrapper->p->environment), 
    == 0);

  return 0;
}

/**
 We cannot implement this function in Swift because if `clone` occurs while the Swift runtime holds onto a lock, that lock will never be released in the cloned process and may cause a deadlock.
 */
void shwift_spawn(shwift_spawn_parameters_t* parameters) {
  shared_parameter_wrapper_t wrapper = { parameters };
  wrapper.p->outcome.succeeded = false;

  const int STACK_SIZE = 65536;
  char *stack = malloc(STACK_SIZE);
  if (!stack) {
    wrapper.p->outcome.return_value = 0;
    wrapper.p->outcome.line = __LINE__;
    return;
  }
  /**
   - note: We currently use `CLONE_VFORK` for simplicity, but this pauses the parent process until the call to `execve`, or `exit`. Eventually we may want to make this nonblocking.
   */
  pid_t pid = clone(child_fn, stack + STACK_SIZE, CLONE_VFORK, &wrapper);
  /// Even if we failed, we need the `pid` to reap the child process
  wrapper.p->outcome.pid = pid;
  if (pid == -1) {
    wrapper.p->outcome.line = __LINE__;
    wrapper.p->outcome.error = errno;
  }
  
  free(stack);
}

#endif
