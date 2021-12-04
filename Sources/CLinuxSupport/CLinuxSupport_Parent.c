
#ifdef __linux__

#include "CLinuxSupportInternal.h"

#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <semaphore.h>
#include <sched.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

// MARK: - String Array

static void ShwiftStringArrayInit(ShwiftStringArray *array, int capacity) {
  array->capacity = capacity;
  array->count = 0;
  /// Allocate an extra element for the NULL terminator
  array->elements = calloc(capacity + 1, sizeof(char *));
  assert(array->elements != NULL);
}

/**
 **Copies** `element` into this array, `element` **must** be a NULL-terminated string.
 */
static void ShwiftStringArrayAppend(ShwiftStringArray* array, const char *element) {
  assert(array->capacity >= array->count + 1);
  char *duplicate = strdup(element);
  assert(duplicate != NULL);
  array->elements[array->count] = duplicate;
  array->count += 1;
}

static void ShwiftStringArrayDestroy(ShwiftStringArray *array) {
  for (int i = 0; i < array->count; i += 1) {
    free(array->elements[i]);
  }
  free(array->elements);
  array->elements = NULL;
}

// MARK: - Outcome

/**
 Creates an invocation outcome which will be shared across child processes. If non-NULL the caller is responsible for calling `ShwiftSpawnInvocationOutcomeComplete` to clean up this invocation once it is complete.

 - Note: Any children which are spawned while this values is alive will inherit the shared memory associated with it. We aren't too worried about this because they can't write to it unless they have a pointer to the mapped memory region. Theoretically, they could overwrite `semaphore` or `mutex` and cause undefined behavior but executing an arbitrary process is alreay a big enough security concern that we probably don't need to worry about this.
 */
static ShwiftSpawnInvocationOutcome *ShwiftSpawnInvocationOutcomeInit() {
  ShwiftSpawnInvocationOutcome *outcome = mmap(
    NULL, 
    sizeof(ShwiftSpawnInvocationOutcome), 
    PROT_READ | PROT_WRITE, 
    MAP_ANONYMOUS | MAP_SHARED, 
    -1,
    0);
  assert(outcome != MAP_FAILED);

  /// Initialize synchronization primitives
  {
    int result;
    pthread_mutexattr_t attributes;
    result = pthread_mutexattr_init(&attributes);
    assert(result == 0);
    /**
     Robust mutexes can detect if their owner `exec`, unmapping the shared memory. We use this to detect that we successfully launched the child process.
     */
    result = pthread_mutexattr_setrobust(&attributes, PTHREAD_MUTEX_ROBUST);
    assert(result == 0);
    /// Fail on recursive lock
    result = pthread_mutexattr_settype(&attributes, PTHREAD_MUTEX_ERRORCHECK);
    assert(result == 0);
    /// This mutex will be shared across processes
    result = pthread_mutexattr_setpshared(&attributes, PTHREAD_PROCESS_SHARED);
    assert(result == 0);
    result = pthread_mutex_init(&outcome->mutex, &attributes);
    assert(result == 0);
    result = pthread_mutexattr_destroy(&attributes);
    assert(result == 0);

    result = sem_init(&outcome->semaphore, /*pshared=*/1, /*value=*/0);
    assert(result == 0);
  }
  outcome->isComplete = false;

  return outcome;
}

/**
 Ensures the invocation outcome is complete and destroys it.

 - Returns: If the child process was launched successfully, returns `true`. Otherwise returns `false` and writes information about the failure into `failure`.
 */
static bool ShwiftSpawnInvocationOutcomeComplete(ShwiftSpawnInvocationOutcome* outcome, ShwiftSpawnInvocationFailure* failure) {
  int result;
  bool isSuccess;

  /// Validate this invocation is complete
  {
    /// The child should not use the semaphore again after signaling it
    result = sem_trywait(&outcome->semaphore);
    assert(result == 0);
    int lockResult = pthread_mutex_trylock(&outcome->mutex);
    if (lockResult == EOWNERDEAD) {
      /// The child died without releasing the mutex
      result = pthread_mutex_consistent(&outcome->mutex);
      assert(result == 0);
    } else {
      assert(lockResult == 0);
    }
    
    /// Critical Section
    if (lockResult == EOWNERDEAD) {
      isSuccess = false;
      failure->file = __FILE__;
      failure->line = __LINE__;
      failure->errorNumber = EOWNERDEAD;
      failure->returnValue = EOWNERDEAD;
    } else {
      assert(outcome->isComplete);
      isSuccess = outcome->isSuccess;
      if (!isSuccess) {
        *failure = outcome->failure;
      }
    }

    result = pthread_mutex_unlock(&outcome->mutex);
    assert(result == 0);
  }
  
  /// Destroy the outcome
  result = pthread_mutex_destroy(&outcome->mutex);
  assert(result == 0);
  result = sem_destroy(&outcome->semaphore);
  assert(result == 0);
  result = munmap(outcome, sizeof(*outcome));
  assert(result == 0);

  return isSuccess;
}

// MARK: - Invocation 

void ShwiftSpawnInvocationAddArgument(ShwiftSpawnInvocation* invocation, const char* argument) {
  ShwiftStringArrayAppend(&invocation->parameters.arguments, argument);
}

void ShwiftSpawnInvocationAddEnvironmentEntry(ShwiftSpawnInvocation* invocation, const char* entry) {
  ShwiftStringArrayAppend(&invocation->parameters.environment, entry);
}

void ShwiftSpawnInvocationAddFileDescriptorMapping(
  ShwiftSpawnInvocation* invocation,
  int source,
  int target)
{
  int count = invocation->parameters.fileDescriptorMappings.count;
  assert(invocation->parameters.fileDescriptorMappings.capacity >= count + 1);
  for (int i = 0; i < invocation->parameters.fileDescriptorMappings.count; i += 1) {
    assert(target != invocation->parameters.fileDescriptorMappings.elements[i].target);
  }
  invocation->parameters.fileDescriptorMappings.elements[count].source = source;
  invocation->parameters.fileDescriptorMappings.elements[count].target = target;
  invocation->parameters.fileDescriptorMappings.count += 1;
}

ShwiftSpawnInvocation* ShwiftSpawnInvocationCreate(
  const char* executablePath,
  const char* workingDirectory,
  int argumentCapacity,
  int environmentCapacity,
  int fileDescriptorMappingsCapacity)
{
  ShwiftSpawnInvocation *invocation = calloc(1, sizeof(ShwiftSpawnInvocation));
  assert(invocation != NULL);
  invocation->parameters.executablePath = strdup(executablePath);
  assert(invocation->parameters.executablePath != NULL);
  invocation->parameters.workingDirectory = strdup(workingDirectory);
  assert(invocation->parameters.workingDirectory != NULL);
  ShwiftStringArrayInit(&invocation->parameters.arguments, argumentCapacity);
  ShwiftStringArrayInit(&invocation->parameters.environment, environmentCapacity);
  invocation->parameters.fileDescriptorMappings.capacity = fileDescriptorMappingsCapacity;
  invocation->parameters.fileDescriptorMappings.elements = calloc(
    fileDescriptorMappingsCapacity, 
    sizeof(invocation->parameters.fileDescriptorMappings.elements[0])
  );
  assert(invocation->parameters.fileDescriptorMappings.elements != NULL);

  invocation->outcome = ShwiftSpawnInvocationOutcomeInit();
  assert(invocation->outcome != NULL);

  return invocation;
}

bool ShwiftSpawnInvocationComplete(ShwiftSpawnInvocation* invocation, ShwiftSpawnInvocationFailure* failure) {
  int isSuccess = ShwiftSpawnInvocationOutcomeComplete(invocation->outcome, failure);
  /// Parameters should have already been freed by `Launch`
  free(invocation);
  return isSuccess;
}

pid_t ShwiftSpawnInvocationLaunch(
  ShwiftSpawnInvocation* invocation,
  int monitor
) {
  invocation->parameters.monitor = monitor;

  /**
   We don't use `CLONE_VM` because it feels super dangerous. With `CLONE_VM`, if a signal handler executes in both the child and the parent, it could put the shared memory into an inconsistent state. Also, if there is a bug in `RunsInClone` it could affect the parent.
   */
  pid_t pid = clone((int(*)(void*))RunsInClone, &(invocation->stackTop), 0, invocation);

  /// Now that we have run `clone`, we can free the parameters in the parent
  free(invocation->parameters.executablePath);
  invocation->parameters.executablePath = NULL;
  free(invocation->parameters.workingDirectory);
  invocation->parameters.workingDirectory = NULL;
  ShwiftStringArrayDestroy(&invocation->parameters.arguments);
  ShwiftStringArrayDestroy(&invocation->parameters.environment);
  free(invocation->parameters.fileDescriptorMappings.elements);
  invocation->parameters.fileDescriptorMappings.elements = NULL;

  return pid;
}

#endif

