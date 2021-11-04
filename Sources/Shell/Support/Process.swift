#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
import CLinuxSupport
#else
#error("Unsupported Platform")
#endif

@_implementationOnly import NIO
import SystemPackage

// MARK: - API

extension Shell {

  public func execute(_ executable: Executable, arguments: [String]) async throws {
    try await invoke { invocation in
      let fileDescriptorMapping: KeyValuePairs<FileDescriptor, FileDescriptor> = [
        invocation.standardInput: .standardInput,
        invocation.standardOutput: .standardOutput,
        invocation.standardError: .standardError,
      ]
      let spawnContext: OpaquePointer = executable.path.withPlatformString { executablePath in
        workingDirectory.withPlatformString { workingDirectory in
          let context = ShwiftSpawnContextCreate(
            executablePath, 
            workingDirectory,
            Int32(arguments.count + 1),
            Int32(environment.count),
            Int32(fileDescriptorMapping.count))!
          ShwiftSpawnContextAddArgument(context, executablePath)
          return context
        }
      }
      for (source, target) in fileDescriptorMapping {
        ShwiftSpawnContextAddFileDescriptorMapping(spawnContext, source.rawValue, target.rawValue)
      }
      for argument in arguments {
        argument.withCString { argument in
          ShwiftSpawnContextAddArgument(spawnContext, argument)
        }
      }
      for (key, value) in environment.sorted(by: { $0.key < $1.key }) {
        ShwiftSpawnContextAddEnvironmentEntry(spawnContext, "\(key)=\(value)")
      }
      defer { ShwiftSpawnContextDestroy(spawnContext) }
      let process = try await waitForFileDescriptorToClose { monitor in
        Process(id: ShwiftSpawn(spawnContext, monitor.rawValue))
      }
      if let process = process {
        print("\(#fileID):\(#line) (\(process.id): \(executable.path.lastComponent!.string))")
        invocation.cancellationHandler = {
          process.terminate()
        }
        invocation.cleanupTask = {
          /**
           Theoretically we shouldn't need to block but there is a race condition where the file descriptor can be closed prior to the process becoming waitable. In the future, we can catch `monitorClosedPriorToProcessTermination` and use a non-blocking fallback (like polling).
           */
          try process.wait(canBlock: true)
        }
      }
      let outcome = ShwiftSpawnContextGetOutcome(spawnContext)
      if !outcome.isSuccess {
        #warning("Should throw an error")
        debugPrint(outcome.payload.failure);
        fatalError()
      }
    }
  }

}

// MARK: - Process

struct Process {

  func terminate() {
    let returnValue = kill(id, SIGTERM)
    assert(returnValue == 0)
  }

  fileprivate init?(id: pid_t) {
    guard id != -1 else {
      return nil
    }
    self.id = id
  }

  fileprivate let id: pid_t
}

// MARK: - Support

// MARK: Errors

extension Process {

  /**
   An error which caused a spawned process to terminate
   */
  enum TerminationError: Swift.Error {
    /**
     Waiting on the process failed.
     */
    case waitFailed(returnValue: CInt, errno: CInt)

    /**
     The monitored file descriptor was closed prior to process termination.
     */
    case monitorClosedPriorToProcessTermination

    /**
     The process terminated successfully, but the termination status was nonzero.
     */
    case nonzeroTerminationStatus(CInt)

    /**
      The process terminated due to an uncaught signal.
      */
    case uncaughtSignal(CInt, coreDumped: Bool)
  }

}

// MARK: Strings

private extension String {

  func duplicateCString() -> UnsafeMutablePointer<CChar>? {
    errno = 0
    guard let duplicate = withCString(strdup) else {
      /// This is the only error `strdup`  should return
      assert(errno == ENOMEM)
      fatalError()
    }
    assert(errno == 0)
    return duplicate
  }
  
}

// MARK: Sharing Memory Between Processes

/**
 Allows mutating a single shared value across any processes spawned during `operation`. THIS IS EXTREMELY UNSAFE, as _only_ the bits of the value will be shared; any references in the value will _only_ exist in the process that created them. For example, setting this value to a `String` is unsafe, since a long enough string will be allocated on the heap, which is not shared between processes.
 */
private func withVeryUnsafeShared<Value, Outcome>(
  _ initialValue: Value,
  operation: (UnsafeMutablePointer<Value>) async throws -> Outcome
) async throws -> Outcome {
  let size = MemoryLayout<Value>.size
  let pointer = mmap(
    nil,
    size,
    PROT_READ | PROT_WRITE,
    MAP_ANONYMOUS | MAP_SHARED,
    -1,
    0)!
  precondition(pointer != MAP_FAILED)
  defer { 
    let returnValue = munmap(pointer, size)
    precondition(returnValue == 0)
  }
  let valuePointer = pointer.bindMemory(to: Value.self, capacity: 1)
  valuePointer.initialize(to: initialValue)
  return try await(operation(valuePointer))
}

// MARK: Waiting on a Process

extension Process {

  /**
   Waits on the process. This call is nonblocking and expects that the process represented by `processID` has already terminated
   */
  fileprivate func wait(canBlock: Bool) throws {
    /// Some key paths are different on Linux and macOS
    #if canImport(Darwin)
    let pid = \siginfo_t.si_pid
    let sigchldInfo = \siginfo_t.self
    let killingSignal = \siginfo_t.si_status
    #elseif canImport(Glibc)
    let pid = \siginfo_t._sifields._sigchld.si_pid
    let sigchldInfo = \siginfo_t._sifields._sigchld
    let killingSignal = \siginfo_t._sifields._rt.si_sigval.sival_int
    #endif

    var info = siginfo_t()
    /**
     We use a process ID of `0` to detect the case when the child is not in a waitable state.
     Since we use the control channel to detect termination, this _shouldn't_ happen (unless the child decides to call `close(3)` for some reason).
     */
    info[keyPath: pid] = 0
    do {
      errno = 0
      let returnValue = waitid(P_PID, id_t(id), &info, WEXITED | __WALL | (canBlock ? 0 : WNOHANG))
      guard returnValue == 0 else {
        throw TerminationError.waitFailed(returnValue: returnValue, errno: errno)
      }
    }
    guard info[keyPath: pid] != 0 else {
      throw TerminationError.monitorClosedPriorToProcessTermination
    }

    switch Int(info.si_code) {
    case Int(CLD_EXITED):
      let terminationStatus = info[keyPath: sigchldInfo].si_status
      guard terminationStatus == 0 else {
        throw TerminationError.nonzeroTerminationStatus(terminationStatus)
      }
    case Int(CLD_KILLED):
      throw TerminationError.uncaughtSignal(info[keyPath: killingSignal], coreDumped: false)
    case Int(CLD_DUMPED):
      throw TerminationError.uncaughtSignal(info[keyPath: killingSignal], coreDumped: true)
    default:
      fatalError()
    }
  }
}

// MARK: Monitoring a file descriptor

private extension Shell {

  /**
   Creates a file descriptor which is valid during `operation`, then waits for that file descriptor and any duplicates to close (including duplicates created as the result of spawning a new process).
   */
  func waitForFileDescriptorToClose<T>(
    _ operation: (FileDescriptor) async throws -> T
  ) async throws -> T {
    let channel: Channel
    let outcome: T
    (channel, outcome) = try await FileDescriptor.withPipe { pipe in
      let channel = try await nioContext.withNullOutputDevice { nullOutput in
        try await NIOPipeBootstrap(group: nioContext.eventLoopGroup)
          .duplicating(
            inputDescriptor: pipe.readEnd,
            outputDescriptor: nullOutput)
      }
      return (channel, try await operation(pipe.writeEnd))
    }
    try await channel.closeFuture.get()
    return outcome
  }

}
