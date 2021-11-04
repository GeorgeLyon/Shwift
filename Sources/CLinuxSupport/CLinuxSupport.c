
#ifdef __linux__

#include <CLinuxSupport.h>

#include <assert.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/types.h>
#include <unistd.h>

/// To debug with strace: strace -o /strace/p -ff .build/debug/ScriptExample

#define _REPORT_FAILURE(outcome, failingReturnValue) \
  ({ \
    (outcome).isSuccess = false; \
    (outcome).payload.failure.line = __LINE__; \
    (outcome).payload.failure.returnValue = (intptr_t)({ failingReturnValue; }); \
    (outcome).payload.failure.error = errno; \
    return -1; \
  })

/// `ShwiftSpawnContext` == `ShwiftSpawnOutcome`
ShwiftSpawnContext* ShwiftSpawnContextCreate() {
  /**
   `ShwiftSpawnContext`s are actualy regions of shared memory. Unfortunately, shared memory is inherited by _all_ child processes which spawn while the shared memory is mapped. This means it is very possible for a child process to inherit an unrelated `ShwiftSpawnContext`. While not ideal, we are OK with this as it is unlikely that a process will accidentally modify this value (mapping and allocating memory in the child process will not overlap this region) and since `ShwiftSpawnContext` is mainly informative and composed of simple integer data types there is little opportunity for mischief by malicious executables.
   */
  ShwiftSpawnOutcome *outcome = mmap(
    NULL,
    sizeof(ShwiftSpawnOutcome),
    PROT_READ | PROT_WRITE,
    MAP_ANONYMOUS | MAP_SHARED,
    -1,
    0);
  if (outcome == MAP_FAILED) {
    return NULL;
  }
  void *memsetResult = memset((void*)outcome, 0, sizeof(ShwiftSpawnOutcome));
  assert(memsetResult == outcome);
  return (ShwiftSpawnContext*)outcome;
}

/// `ShwiftSpawnContext` == `ShwiftSpawnOutcome`
bool ShwiftSpawnContextDestroy(ShwiftSpawnContext* context) {
  return munmap(context, sizeof(ShwiftSpawnOutcome)) == 0;
}

/// `ShwiftSpawnContext` == `ShwiftSpawnOutcome`
ShwiftSpawnOutcome ShwiftSpawnContextGetOutcome(ShwiftSpawnContext* context) {
  /// The extra `volatile` may be unnecessary, but shared memory is scary so let's play it safe.
  ShwiftSpawnOutcome volatile* volatile outcome;
  outcome = (typeof(outcome))context;
  return *outcome;
}

typedef struct {
  const char* executablePath;
  char* const* arguments;
  const char* workingDirectory;
  char* const* environment;
  int fileDescriptorMappingsCount;
  const ShwiftSpawnFileDescriptorMapping* fileDescriptorMappings;
  int monitor;
} ShwiftSpawnParameters;

typedef struct {
  ShwiftSpawnParameters parameters;

  /// The extra `volatile` may be unnecessary, but shared memory is scary so let's play it safe.
  ShwiftSpawnOutcome volatile* volatile outcome;
} ShwiftSpawnCloneArguments;

/**
 We cannot implement this function in Swift because if `clone` occurs while the Swift runtime holds a lock on a different thread, that lock will never be released in the cloned process and may cause a deadlock.
 */
static int RunsInClone(ShwiftSpawnCloneArguments* cloneArguments) {
  #define EXPECT(expression, expectation) \
    ({  \
      errno = 0; \
      typeof(expression) returnValue = ({ expression; }); \
      if (!((returnValue expectation) && (errno == 0))) { \
        _REPORT_FAILURE(*cloneArguments->outcome, returnValue); \
      } \
      returnValue; \
    })
  /// `== returnValue` creates a tautology, so only the errno check remains.
  #define CHECK_ERRNO(expression) EXPECT(expression, == returnValue)

  /// Create a new mapping with temporary file descriptors which do not correspond to a target file descriptor.
  /// `mapping` never needs to be freed because we will be exiting or execing this process
  int fileDescriptorMappingsCount = cloneArguments->parameters.fileDescriptorMappingsCount;

  /// We can't even allocate anything because we might have cloned while the heap is locked...
  ShwiftSpawnFileDescriptorMapping fileDescriptorMappings[fileDescriptorMappingsCount];
  // ShwiftSpawnFileDescriptorMapping* fileDescriptorMappings = 
    // calloc(fileDescriptorMappingsCount, sizeof(ShwiftSpawnFileDescriptorMapping));
  for (int i = 0; i < fileDescriptorMappingsCount; i++) {
    while (true) {
      int source = cloneArguments->parameters.fileDescriptorMappings[i].source;
      int temporary = EXPECT(dup(source), != -1);
      bool isTarget = false;
      for (int i = 0; i < fileDescriptorMappingsCount; i++) {
        if (temporary == cloneArguments->parameters.fileDescriptorMappings[i].target) {
          isTarget = true;
          break;
        }
      }
      if (!isTarget) {
        fileDescriptorMappings[i].source = temporary;
        fileDescriptorMappings[i].target = cloneArguments->parameters.fileDescriptorMappings[i].target; 
        break;
      }
    }
  }
  /// Close all open file descriptors except the new temporaries.
  int directoryDescriptor = EXPECT(open("/proc/self/fd", O_RDONLY | O_DIRECTORY), != -1);
  DIR* directory = EXPECT(fdopendir(directoryDescriptor), != NULL);
  struct dirent *entry;

  while (( entry = CHECK_ERRNO(readdir(directory)) )) {
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
    int descriptor = (int)EXPECT(strtol(entry->d_name, &endptr, 10), < INT_MAX);
    EXPECT(*endptr, == '\0');
    /// Skip the directory descriptor
    if (descriptor == directoryDescriptor) {
      continue;
    }
    if (descriptor == cloneArguments->parameters.monitor) {
      /// We'll close monitor using `fcntl` 
      continue;
    }

    /// Skip newly-created temporaries
    bool isTemporary = false;
    for (int i = 0; i < fileDescriptorMappingsCount; i++) {
      if (descriptor == fileDescriptorMappings[i].source) {
        isTemporary = true;
        break;
      }
    }
    if (isTemporary) {
      continue;
    }
    EXPECT(close(descriptor), == 0);
  }
  EXPECT(closedir(directory), == 0);
  /// Copy and close temporaries
  for (int i = 0; i < fileDescriptorMappingsCount; i++) {
    int source = fileDescriptorMappings[i].source;
    int target = fileDescriptorMappings[i].target;
    EXPECT(dup2(source, target), == target);
    EXPECT(close(source), == 0);
  }

  EXPECT(chdir(cloneArguments->parameters.workingDirectory), == 0);

  /**
   `monitor` will be closed if `execve` succeeds.
   */
  EXPECT(fcntl(cloneArguments->parameters.monitor, F_SETFD, FD_CLOEXEC), == 0);

  cloneArguments->outcome->payload.failure.line = 42;
  EXPECT(
    execve(
      cloneArguments->parameters.executablePath, 
      cloneArguments->parameters.arguments, 
      cloneArguments->parameters.environment), 
    == 0);

  #undef EXPECT
  #undef CHECK_ERRNO
  return 1;
}

pid_t ShwiftSpawn(
  const char* executablePath,
  char* const* arguments,
  const char* workingDirectory,
  char* const* environment,
  int fileDescriptorMappingsCount,
  const ShwiftSpawnFileDescriptorMapping* fileDescriptorMappings,
  ShwiftSpawnContext* context,
  int monitor
) {
  ShwiftSpawnCloneArguments cloneArguments = {
    .parameters = {
      .executablePath = executablePath,
      .arguments = arguments,
      .workingDirectory = workingDirectory,
      .environment = environment,
      .fileDescriptorMappingsCount = fileDescriptorMappingsCount,
      .fileDescriptorMappings = fileDescriptorMappings,
      .monitor = monitor,
    },
    .outcome = (ShwiftSpawnOutcome volatile* volatile)context,
  };
  cloneArguments.outcome->isSuccess = true;

  const int STACK_SIZE = 65536;
  char *stack = malloc(STACK_SIZE);
  if (!stack) {
    _REPORT_FAILURE(*cloneArguments.outcome, stack);
  }

  /**
   - note: We don't specify SIGCHLD because we use other mechanisms to determine when the child process exits.
   */
  pid_t processID = clone((int(*)(void*))RunsInClone, stack + STACK_SIZE, 0, &cloneArguments);

  free(stack);
  return processID;
}

#endif
