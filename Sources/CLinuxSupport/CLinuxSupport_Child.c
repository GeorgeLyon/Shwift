
#include "CLinuxSupportInternal.h"

#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/resource.h>
#include <signal.h>
#include <stdlib.h>

/**
 All code in this file runs in a newly-cloned child. Extreme case must be taken to not use any API which may have been locked in the parent process when `clone` was called (`malloc`, for example).
 */

static void ShwiftSpawnInvocationOutcomeFail(
  ShwiftSpawnInvocationOutcome *outcome, 
  const char *file, 
  intptr_t line, 
  intptr_t returnValue, 
  int errorNumber
) {
  outcome->isComplete = true;
  outcome->isSuccess = false;
  outcome->failure.file = file;
  outcome->failure.line = line;
  outcome->failure.returnValue = returnValue;
  outcome->failure.errorNumber = errorNumber;
  /// The mutex will be unlocked when the child exits
  exit(1);
}

int RunsInClone(ShwiftSpawnInvocation* invocation) {
  #define EXPECT(expression, expectation) \
    ({  \
      errno = 0; \
      typeof(expression) returnValue = ({ expression; }); \
      int errorNumber = errno; \
      if (!((returnValue expectation) && (errorNumber == 0))) { \
        ShwiftSpawnInvocationOutcomeFail(invocation->outcome, __FILE__, __LINE__, returnValue, errorNumber); \
      } \
      returnValue; \
    })

  /// Take ownership of the mutex
  EXPECT(pthread_mutex_trylock(&invocation->outcome->mutex), == 0);
  EXPECT(sem_post(&invocation->outcome->semaphore), == 0);

  /// Duplicate source file descriptors so that they do not overlap with a target
  for (int i = 0; i < invocation->parameters.fileDescriptorMappings.count; i++) {
    while (true) {
      int source = invocation->parameters.fileDescriptorMappings.elements[i].source;
      /// We must `dup` source at least once to ensure each source is unique
      source = EXPECT(dup(source), != -1);
      bool isTarget = false;
      for (int i = 0; i < invocation->parameters.fileDescriptorMappings.count; i++) {
        if (source == invocation->parameters.fileDescriptorMappings.elements[i].target) {
          isTarget = true;
          break;
        }
      }
      if (isTarget) {
        /// The file descriptor matched a target, try again
        continue;
      } else {
        invocation->parameters.fileDescriptorMappings.elements[i].source = source;
        break;
      }
    }
  }

   
  /**
   Close all open file descriptors except the new temporaries.

   - Note: We can't use `/proc/self/fd` because `opendir` and friends can call `malloc` which could cause a deadlock if a lock was aquired when `clone` was called.
   - Note: After this point, stdout might be remapped, so we should take care not to write to it.

   - Note: This takes about 0.12 seconds on my laptop, which dominates the runtime of this prelude (and also the runtime of simpler programs). This isn't ideal, but probably not the end of the world. We could speed it up by iterating over `/proc/<child-id>/fd` in the parent, writing the results to shared memory, and then signaling a semaphore.
   */
  struct rlimit rlim;
  EXPECT(getrlimit(RLIMIT_NOFILE, &rlim), == 0);
  EXPECT(rlim.rlim_cur, != RLIM_INFINITY);
  for (int descriptor = 0; descriptor < rlim.rlim_max; descriptor += 1) {
    /// Skip the monitor
    if (descriptor == invocation->parameters.monitor) {
      continue;
    }

    /// Skip temporaries
    bool isTemporary = false;
    for (int i = 0; i < invocation->parameters.fileDescriptorMappings.count; i++) {
      if (descriptor == invocation->parameters.fileDescriptorMappings.elements[i].source) {
        isTemporary = true;
        break;
      }
    }
    if (isTemporary) {
      continue;
    }

    while (true) {
      errno = 0;
      int result = close(descriptor);
      int errorNumber = errno;
      if (result == -1) {
        if (errorNumber == EINTR) {
          continue;
        } else if (errorNumber == EBADF) {
          /// We are just iterating over all possible descriptors with no guarantee that they are valid
          break;
        }
      }
      EXPECT(({ errno = errorNumber; result; }), == 0);
    }
  }

  /// Copy and close temporaries
  for (int i = 0; i < invocation->parameters.fileDescriptorMappings.count; i++) {
    int source = invocation->parameters.fileDescriptorMappings.elements[i].source;
    int target = invocation->parameters.fileDescriptorMappings.elements[i].target;
    EXPECT(dup2(source, target), == target);
    EXPECT(close(source), == 0);
  }

  /// Change working directory
  EXPECT(chdir(invocation->parameters.workingDirectory), == 0);

  /// Ensure monitor is closed if `execve` succeeds
  EXPECT(fcntl(invocation->parameters.monitor, F_SETFD, FD_CLOEXEC), == 0);

  /// Make sure signals are enabled
  sigset_t allSignals;
  EXPECT(sigfillset(&allSignals), == 0);
  EXPECT(sigprocmask(SIG_UNBLOCK, &allSignals, NULL), == 0);

  /// If `execve` succeeds we need the invocation to be complete.
  invocation->outcome->isComplete = true;
  invocation->outcome->isSuccess = true;

  EXPECT(pthread_mutex_unlock(&invocation->outcome->mutex), == 0);

  EXPECT(
    execve(
      invocation->parameters.executablePath, 
      invocation->parameters.arguments.elements, 
      invocation->parameters.environment.elements), 
    == 0);

  return 1;
  #undef EXPECT
}