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
      try await withVeryUnsafeShared(shwift_spawn_parameters_t()) { parameters in
        let cArguments = ([executable.path.string] + arguments).map { $0.duplicateCString() }
        defer { cArguments.forEach { free($0) } }
        let cEnvironment = environment.map { "\($0.key)=\($0.value)".duplicateCString() }
        defer { cEnvironment.forEach { free($0) } }

        var fileDescriptorMapping: [file_descriptor_mapping_t] = [
          (invocation.standardInput, STDIN_FILENO),
          (invocation.standardOutput, STDOUT_FILENO),
          (invocation.standardError, STDERR_FILENO),
        ].map { file_descriptor_mapping_t(source: $0.0.rawValue, target: $0.1) }

        executable.path.withPlatformString { executablePath in
          (cArguments + [nil]).withUnsafeBufferPointer { arguments in
            (cEnvironment + [nil]).withUnsafeBufferPointer { environment in
              workingDirectory.withPlatformString { workingDirectory in 
                fileDescriptorMapping.withUnsafeMutableBufferPointer { fileDescriptorMapping in
                  parameters.pointee.executablePath = executablePath
                  parameters.pointee.arguments = arguments.baseAddress
                  parameters.pointee.environment = environment.baseAddress
                  parameters.pointee.directory = workingDirectory
                  parameters.pointee.file_descriptor_mapping_count = Int32(fileDescriptorMapping.count)
                  parameters.pointee.file_descriptor_mapping = fileDescriptorMapping.baseAddress
                  shwift_spawn(parameters)
                }
              }
            }
          }
        }
        /// Only `outcome` is valid from this point on
        let outcome = parameters.pointee.outcome
        if outcome.pid != -1 {
          invocation.cancellationHandler = {
            let returnValue = kill(outcome.pid, SIGTERM)
            assert(returnValue == 0)
          }
          invocation.cleanupTask = {
            try Process.wait(on: outcome.pid, canBlock: true)
          }
        }

        precondition(parameters.pointee.outcome.succeeded)
      }
    }
  }

}

// MARK: - Process

struct Process {

  func terminate() {
    let returnValue = kill(id, SIGTERM)
    precondition(returnValue == 0)
  }

  private let id: pid_t
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
  fileprivate static func wait(on processID: pid_t, canBlock: Bool) throws {
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
      let returnValue = waitid(P_PID, id_t(processID), &info, WEXITED | __WALL | (canBlock ? 0 : WNOHANG))
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
