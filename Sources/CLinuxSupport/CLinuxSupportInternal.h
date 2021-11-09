
#ifndef __CLINUXSUPPORTINTERNAL_H
#define __CLINUXSUPPORTINTERNAL_H

#ifdef __linux__

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <CLinuxSupport.h>
#include <semaphore.h>
#include <pthread.h>

/**
 A type which is shared between the cloned child and the parent.

 `semaphore` starts at 0, and it is the role of the child to signal the semaphore once it has aquired `mutex`. `mutex` should remain locked in the child exits or successfully calls `exeve`.
 Both a sempahore and a mutex are needed because we need to start in a locked state which the child unlocks when it is ready. Robust mutexes are convenient since they allow us to detect if their owner dies. Unfortunately, mutexes should only be unlocked by the thread/process which locked them, so we must use a semaphore (which can be signaled on any process) to transfer the ownership.
 */
typedef struct {
  sem_t semaphore;
  pthread_mutex_t mutex;
  bool isComplete;
  bool isSuccess;
  ShwiftSpawnInvocationFailure failure;
} ShwiftSpawnInvocationOutcome;

/**
 A NULL-terminated array.
 */
typedef struct {
  int capacity, count;
  char **elements;
} ShwiftStringArray;

/**
 The invocation data passed to the child process
 */
struct ShwiftSpawnInvocation {
  char stack[4096];
  char stackTop;

  struct {
    char* executablePath;
    char* workingDirectory;
    ShwiftStringArray arguments;
    ShwiftStringArray environment;

    struct {
      int capacity, count;
      struct {
        int source, target;
      } *elements;
    } fileDescriptorMappings;

    int monitor;
  } parameters;

  ShwiftSpawnInvocationOutcome *outcome;
};

int RunsInClone(ShwiftSpawnInvocation* invocation);

#endif // __linux__

#endif // __CLINUXSUPPORTINTERNAL_H