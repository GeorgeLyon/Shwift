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

  public func execute(_ executable: Executable, withArguments arguments: [String]) async throws {
    logger?.willLaunch(executable, withArguments: arguments, in: workingDirectory)
    
    try await withIO { io in
      try await monitorFileDescriptor { monitor in
        let fileDescriptorMapping: KeyValuePairs = [
          io.standardInput: .standardInput,
          io.standardOutput: .standardOutput,
          io.standardError: .standardError,
          monitor.descriptor: FileDescriptor(rawValue: STDERR_FILENO + 1)
        ]
        precondition(Set(fileDescriptorMapping.map(\.value)).count == fileDescriptorMapping.count)
      
        let process: Process
        do {
          #if canImport(Darwin)
          var attributes = try PosixSpawn.Attributes()
          defer { try! attributes.destroy() }
          try attributes.setFlags(.closeFileDescriptorsByDefault)
          
          var actions = try PosixSpawn.FileActions()
          defer { try! actions.destroy() }
          try actions.addChangeDirectory(to: workingDirectory)
          for (source, target) in fileDescriptorMapping {
            try actions.addDuplicate(source, as: target)
          }
        
          let id = Process.ID(
            rawValue: try PosixSpawn.spawn(
              executable.path,
              arguments: [executable.path.string] + arguments,
              environment: environment,
              fileActions: &actions,
              attributes: &attributes))!
          process = Process(id: id)
          #elseif canImport(Glibc)
          let invocation: OpaquePointer = executable.path.withPlatformString { executablePath in
            workingDirectory.withPlatformString { workingDirectory in
              ShwiftSpawnInvocationCreate(
                executablePath,
                workingDirectory,
                Int32(arguments.count + 1),
                Int32(environment.count),
                Int32(fileDescriptorMapping.count))!
            }
          }

          /// Use a closure to make sure no errors are thrown before we can complete the invocation
          process = await {
            for (source, target) in fileDescriptorMapping {
              ShwiftSpawnInvocationAddFileDescriptorMapping(invocation, source.rawValue, target.rawValue)
            }

            executable.path.withPlatformString { path in
              ShwiftSpawnInvocationAddArgument(invocation, path)
            }
            for argument in arguments {
              argument.withCString { argument in
                ShwiftSpawnInvocationAddArgument(invocation, argument)
              }
            }
            
            for (key, value) in environment.sorted(by: { $0.key < $1.key }) {
              ShwiftSpawnInvocationAddEnvironmentEntry(invocation, "\(key)=\(value)")
            }

            return try! await monitorFileDescriptor { monitor in
              Process(
                id: Process.ID(
                  rawValue: ShwiftSpawnInvocationLaunch(invocation, monitor.descriptor.rawValue))!)
            }
          }()
          var failure = ShwiftSpawnInvocationFailure();
          guard ShwiftSpawnInvocationComplete(invocation, &failure) else {
            throw Process.SpawnError(
              file: String(cString: failure.file),
              line: failure.line,
              returnValue: failure.returnValue,
              errorNumber: failure.errorNumber)
          }
          #endif
        }

        logger?.process(process, didLaunchWith: executable, arguments: arguments, in: workingDirectory)
        monitor.cancellationHandler = {
          process.terminate()
        }
        monitor.completionHandler = {
          /**
           Theoretically we shouldn't need to block but there is a race condition where the file descriptor can be closed prior to the process becoming waitable. In the future, we can catch `monitorClosedPriorToProcessTermination` and use a non-blocking fallback (like polling).
           */
          do {
            try process.wait(canBlock: true)
            logger?.process(process, for: executable, withArguments: arguments, in: workingDirectory, didComplete: nil)
          } catch {
            logger?.process(process, for: executable, withArguments: arguments, in: workingDirectory, didComplete: error)
            throw error
          }
        }
      }
    }
  }

}

// MARK: - Process

typealias Process = Shell.Process

extension Shell {
  public struct Process {

    func terminate() {
      let returnValue = kill(id.rawValue, SIGTERM)
      assert(returnValue == 0)
    }

    fileprivate init(id: ID) {
      self.id = id
    }

    public struct ID: RawRepresentable {
      public init?(rawValue: pid_t) {
        guard rawValue != -1 else {
          return nil
        }
        self.rawValue = rawValue
      }
      public let rawValue: pid_t
    }
    public let id: ID
  }
}

// MARK: - Support

// MARK: Errors

extension Process {

  struct SpawnError: Swift.Error {
    let file: String
    let line: Int
    let returnValue: Int
    let errorNumber: CInt
  }

  /**
   An error which caused a spawned process to terminate
   */
  public enum TerminationError: Swift.Error {
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
      var flags = WEXITED
      #if canImport(Glibc)
      flags |= __WALL
      #endif
      if !canBlock {
        flags |= WNOHANG
      }
      let returnValue = waitid(P_PID, id_t(id.rawValue), &info, flags)
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

// MARK: Monitoring file descriptors

private extension Shell {
  
  struct FileDescriptorMonitor {
    /**
     The descriptor being monitored. `monitorFileDescriptor` will wait on this descriptor an any duplicates to close before returning.
     */
    let descriptor: FileDescriptor
    
    /**
     A closure which runs if the task is cancelled before `monitorFileDescriptor` returns
     */
    var cancellationHandler: (() -> Void)?

    /**
     A closure which will be run after `descriptor` is closed but before `monitorFileDescriptor` returns
     */
    var completionHandler: (() throws -> Void)?
  }
  
  /**
   Creates a file descriptor which is valid during `operation`, then waits for that file descriptor and any duplicates to close (including duplicates created as the result of spawning a new process).
   */
  func monitorFileDescriptor<T>(
    _ operation: (inout FileDescriptorMonitor) async throws -> T
  ) async throws -> T {
    let future: EventLoopFuture<T>
    let unsafeMonitor: FileDescriptorMonitor
    (future, unsafeMonitor) = try await FileDescriptor.withPipe { pipe in
      let channel = try await withNullOutputDevice { nullOutput in
        try await NIOPipeBootstrap(group: nioContext.eventLoopGroup)
          .channelInitializer { channel in
            channel.pipeline.addHandler(MonitorHandler())
          }
          .duplicating(
            inputDescriptor: pipe.readEnd,
            outputDescriptor: nullOutput)
      }
      var monitor = FileDescriptorMonitor(descriptor: pipe.writeEnd)
      let outcome = try await operation(&monitor)
      let future = channel.closeFuture.map { _ in outcome }
      return (future, monitor)
    }
    /// `unsafeMonitor.descriptor` may be invalid at this point
    let outcome: T = await withTaskCancellationHandler(
      handler: {
        unsafeMonitor.cancellationHandler?()
      },
      operation: {
        /// `future` can only be awaited on after `withPipe` returns, closing the temporary descriptors.
        let outcome = try! await future.get()
        return outcome
      })
    try unsafeMonitor.completionHandler?()
    return outcome
  }
  
  private final class MonitorHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
      /**
       Writing data on the monitor descriptor is probably an error. In the future we might want to make incoming data cancel the invocation.
       */
      assertionFailure()
    }
  }

}
