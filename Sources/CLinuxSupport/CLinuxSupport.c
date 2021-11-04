
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

/**
 Code running in the cloned process is a pain to debug, but this mechanism at least lets us pull out some information about a failure if we run into one.
 */
#define _REPORT_FAILURE(context, failingReturnValue) \
  ({ \
    ShwiftSpawnContext* ctx = ({ context; }); \
    ctx->isComplete = true; \
    ctx->outcome.isSuccess = false; \
    ctx->outcome.payload.failure.file = __FILE__; \
    ctx->outcome.payload.failure.line = __LINE__; \
    ctx->outcome.payload.failure.returnValue = (intptr_t)({ failingReturnValue; }); \
    ctx->outcome.payload.failure.error = errno; \
    return -1; \
  })

#define ASSERT_NONNULL(expression) \
  ({ \
    typeof(expression) value = ({ expression; }); \
    assert(value != NULL); \
    value; \
  })

// MARK: - String Array

/**
 A NULL-terminated array.
 */
typedef struct {
  int capacity, count;
  char **elements;
} ShwiftSpawnStringArray;

static void ShwiftSpawnStringArrayInit(ShwiftSpawnStringArray *array, int capacity) {
  array->capacity = capacity;
  array->count = 0;
  /// Allocate an extra element for the NULL terminator
  array->elements = ASSERT_NONNULL(calloc(capacity + 1, sizeof(char *)));
}

/**
 **Copies** `element` into this array, `element` **must** be a NULL-terminated string.
 */
static void ShwiftSpawnStringArrayAppend(ShwiftSpawnStringArray* array, const char *element) {
  assert(array->capacity >= array->count + 1);
  array->elements[array->count] = ASSERT_NONNULL(strdup(element));
  array->count += 1;
}

static void ShwiftSpawnStringArrayDestroy(ShwiftSpawnStringArray *array) {
  for (int i = 0; i < array->count; i += 1) {
    free(array->elements[i]);
  }
  free(array->elements);
}

// MARK: - Context

typedef struct {
  int source, target;
} ShwiftSpawnFileDescriptorMapping;

struct ShwiftSpawnContext {
  char stack[65536];
  char stackTop;

  struct {
    char* executablePath;
    char* workingDirectory;
    ShwiftSpawnStringArray arguments;
    ShwiftSpawnStringArray environment;

    struct {
      int capacity, count;
      ShwiftSpawnFileDescriptorMapping *elements;
    } fileDescriptorMappings;

    int monitor;
  } parameters;

  bool isComplete;
  ShwiftSpawnOutcome outcome;
};

ShwiftSpawnContext* ShwiftSpawnContextCreate(
  const char* executablePath,
  const char* workingDirectory,
  int argumentCapacity,
  int environmentCapacity,
  int fileDescriptorMappingsCapacity)
{
  ShwiftSpawnContext *context = ASSERT_NONNULL(calloc(1, sizeof(ShwiftSpawnContext)));
  context->parameters.executablePath = ASSERT_NONNULL(strdup(executablePath));
  context->parameters.workingDirectory = ASSERT_NONNULL(strdup(workingDirectory));
  ShwiftSpawnStringArrayInit(&context->parameters.arguments, argumentCapacity);
  ShwiftSpawnStringArrayInit(&context->parameters.environment, environmentCapacity);
  context->parameters.fileDescriptorMappings.capacity = fileDescriptorMappingsCapacity;
  context->parameters.fileDescriptorMappings.elements = ASSERT_NONNULL(calloc(fileDescriptorMappingsCapacity, sizeof(ShwiftSpawnFileDescriptorMapping)));
  return context;
}

void ShwiftSpawnContextDestroy(ShwiftSpawnContext* context) {
  free(context->parameters.executablePath);
  free(context->parameters.workingDirectory);
  ShwiftSpawnStringArrayDestroy(&context->parameters.arguments);
  ShwiftSpawnStringArrayDestroy(&context->parameters.environment);
  free(context->parameters.fileDescriptorMappings.elements);
  free(context);
}

void ShwiftSpawnContextAddArgument(ShwiftSpawnContext* context, const char* argument) {
  ShwiftSpawnStringArrayAppend(&context->parameters.arguments, argument);
}

void ShwiftSpawnContextAddEnvironmentEntry(ShwiftSpawnContext* context, const char* entry) {
  ShwiftSpawnStringArrayAppend(&context->parameters.environment, entry);
}

void ShwiftSpawnContextAddFileDescriptorMapping(
  ShwiftSpawnContext* context,
  int source,
  int target)
{
  int count = context->parameters.fileDescriptorMappings.count;
  assert(context->parameters.fileDescriptorMappings.capacity >= count + 1);
  context->parameters.fileDescriptorMappings.elements[count].source = source;
  context->parameters.fileDescriptorMappings.elements[count].target = target;
  context->parameters.fileDescriptorMappings.count += 1;
}

ShwiftSpawnOutcome ShwiftSpawnContextGetOutcome(ShwiftSpawnContext* context) {
  assert(context->isComplete);
  return context->outcome;
}

/**
 We cannot implement this function in Swift because if we do not specify `CLONE_VM` and `clone` occurs while the Swift runtime (or even just `malloc`) holds a lock on a different thread, that lock will never be released in the cloned process and may cause a deadlock. On the other hand, if we specify `CLONE_VM`, anything reference-counted passed to the clone will not have its reference count increased and thus may be freed prematurely.
 */
static int RunsInClone(ShwiftSpawnContext* context) {
  #define EXPECT(expression, expectation) \
    ({  \
      errno = 0; \
      typeof(expression) returnValue = ({ expression; }); \
      if (!((returnValue expectation) && (errno == 0))) { \
        _REPORT_FAILURE(context, returnValue); \
      } \
      returnValue; \
    })
  /// `== returnValue` creates a tautology, so only the errno check remains.
  #define CHECK_ERRNO(expression) EXPECT(expression, == returnValue)

  for (int i = 0; i < context->parameters.fileDescriptorMappings.count; i++) {
    while (true) {
      int source = context->parameters.fileDescriptorMappings.elements[i].source;
      bool isTarget = false;
      for (int i = 0; i < context->parameters.fileDescriptorMappings.count; i++) {
        if (source == context->parameters.fileDescriptorMappings.elements[i].target) {
          isTarget = true;
          break;
        }
      }
      if (isTarget) {
        context->parameters.fileDescriptorMappings.elements[i].source = EXPECT(dup(source), != -1);
        continue;
      } else {
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
    if (descriptor == context->parameters.monitor) {
      /// We'll close monitor using `fcntl` 
      continue;
    }

    /// Skip newly-created temporaries
    bool isTemporary = false;
    for (int i = 0; i < context->parameters.fileDescriptorMappings.count; i++) {
      if (descriptor == context->parameters.fileDescriptorMappings.elements[i].source) {
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
  for (int i = 0; i < context->parameters.fileDescriptorMappings.count; i++) {
    int source = context->parameters.fileDescriptorMappings.elements[i].source;
    int target = context->parameters.fileDescriptorMappings.elements[i].target;
    EXPECT(dup2(source, target), == target);
    EXPECT(close(source), == 0);
  }

  EXPECT(chdir(context->parameters.workingDirectory), == 0);

  /**
   `monitor` will be closed if `execve` succeeds.
   */
  EXPECT(fcntl(context->parameters.monitor, F_SETFD, FD_CLOEXEC), == 0);

  /// If `execve` succeeds we need the context to be complete.
  context->outcome.isSuccess = true;
  context->isComplete = true;

  EXPECT(
    execve(
      context->parameters.executablePath, 
      context->parameters.arguments.elements, 
      context->parameters.environment.elements), 
    == 0);

  #undef EXPECT
  #undef CHECK_ERRNO
  return 1;
}

pid_t ShwiftSpawn(
  ShwiftSpawnContext* context,
  int monitor
) {
  context->parameters.monitor = monitor;
  context->isComplete = false;
  
  /**
   - note: We don't specify SIGCHLD because we use other mechanisms to determine when the child process exits.
   - note: We use `CLONE_VM`, because without that we might deadlock if the clone happens while a low-level lock has been taken (for instance, in `malloc`).
   - note: `clone` duplicates `monitor` (and other file descriptors)
   */
  return clone((int(*)(void*))RunsInClone, &(context->stackTop), CLONE_VM, context);
}

#endif
