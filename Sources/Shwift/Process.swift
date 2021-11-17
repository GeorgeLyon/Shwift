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

public struct Process {

  public static func run(
    executablePath: FilePath,
    arguments: [String],
    environment: Environment,
    workingDirectory: FilePath,
    fileDescriptors: FileDescriptorMapping,
    logger: ProcessLogger? = nil,
    in context: Context
  ) async throws {
    let process = try! await context.monitorFileDescriptor { monitor -> Process in
      do {
        var fileDescriptors = fileDescriptors
        /// Map the monitored descriptor to the lowest unmapped target descriptor
        let mappedFileDescriptors = Set(fileDescriptors.entries.map(\.target))
        fileDescriptors.addMapping(
          from: monitor.descriptor,
          to: (0...).first(where: { !mappedFileDescriptors.contains($0) })!)
        let process = try await Process(
          executablePath: executablePath,
          arguments: arguments,
          environment: environment,
          workingDirectory: workingDirectory,
          fileDescriptors: fileDescriptors,
          context: context)
        logger?.didLaunch(process)
        monitor.cancellationHandler = { process.terminate() }
        return process
      } catch {
        logger?.failedToLaunchProcess(dueTo: error)
        throw error
      }
    }
    logger?.willWait(on: process)
    do {
      let start = clock()
      try process.wait(allowBlocking: true)
      let end = clock()
      if end - start > 1 * CLOCKS_PER_SEC {
        /**
         We currently do not set `block` because during child process termination the `monitor` file descriptor is not closed atomically with the child process becoming waitable. Normally, this shouldn't be an issue but misbehaved children could cause a problem by closing the `monitor` early and not terminating. If this becomes an issue we should first wait with `WNOHANG` and if the wait fails delegate to a helper thread which will poll until the process is terminated (polling would be preferable to blocking because then we can support an abitrary number of child processes without creating a thread explosion).
         */
        print("\(#filePath):\(#line) warning: \(process) waited for longer than 1 second for termination.")
      }
      logger?.process(process, didTerminateWithError: nil)
    } catch {
      logger?.process(process, didTerminateWithError: error)
    }
  }

  private init(
    executablePath: FilePath,
    arguments: [String],
    environment: Environment,
    workingDirectory: FilePath,
    fileDescriptors: FileDescriptorMapping,
    context: Context
  ) async throws {
    #if canImport(Darwin)
    var attributes = try PosixSpawn.Attributes()
    defer { try! attributes.destroy() }
    try attributes.setFlags([
      .closeFileDescriptorsByDefault,
      .setSignalMask,
    ])
    try attributes.setBlockedSignals(to: .none)
    
    var actions = try PosixSpawn.FileActions()
    defer { try! actions.destroy() }
    try actions.addChangeDirectory(to: workingDirectory)
    for entry in fileDescriptors.entries {
      try actions.addDuplicate(entry.source, as: entry.target)
    }
  
    id = ID(
      rawValue: try PosixSpawn.spawn(
        executablePath,
        arguments: [executablePath.string] + arguments,
        environment: environment.strings,
        fileActions: &actions,
        attributes: &attributes))!
    #elseif canImport(Glibc)
    let invocation: OpaquePointer = executablePath.withPlatformString { executablePath in
      workingDirectory.withPlatformString { workingDirectory in
        ShwiftSpawnInvocationCreate(
          executablePath,
          workingDirectory,
          Int32(arguments.count + 1),
          Int32(environment.strings.count),
          Int32(fileDescriptors.entries.count))!
      }
    }

    /// Use a closure to make sure no errors are thrown before we can complete the invocation
    id = await {
      for entry in fileDescriptors.entries {
        ShwiftSpawnInvocationAddFileDescriptorMapping(invocation, entry.source.rawValue, entry.target)
      }

      executablePath.withPlatformString { path in
        ShwiftSpawnInvocationAddArgument(invocation, path)
      }
      for argument in arguments {
        argument.withCString { argument in
          ShwiftSpawnInvocationAddArgument(invocation, argument)
        }
      }
      
      for entry in environment.strings {
        entry.withCString { entry in
          ShwiftSpawnInvocationAddEnvironmentEntry(invocation, entry)
        }
      }

      return try! await context.monitorFileDescriptor { monitor in
        ID(rawValue: ShwiftSpawnInvocationLaunch(invocation, monitor.descriptor.rawValue))!
      }
    }()
    var failure = ShwiftSpawnInvocationFailure();
    guard ShwiftSpawnInvocationComplete(invocation, &failure) else {
      throw SpawnError(
        file: String(cString: failure.file),
        line: failure.line,
        returnValue: failure.returnValue,
        errorNumber: failure.errorNumber)
    }
    #endif
  }

  private func terminate() {
    let returnValue = kill(id.rawValue, SIGTERM)
    assert(returnValue == 0)
  }

  /**
   Waits on the process. This call is nonblocking and expects that the process represented by `processID` has already terminated
   */
  private func wait(allowBlocking: Bool) throws {
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
      if !allowBlocking {
        flags |= WNOHANG
      }
      let returnValue = waitid(P_PID, id_t(id.rawValue), &info, flags)
      guard returnValue == 0 else {
        throw TerminationError.waitFailed(returnValue: returnValue, errno: errno)
      }
    }
    guard info[keyPath: pid] != 0 else {
      throw TerminationError.processIsStillRunning
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

  public struct ID: CustomStringConvertible {
    init?(rawValue: pid_t) {
      guard rawValue != -1 else {
        return nil
      }
      self.rawValue = rawValue
    }
    let rawValue: pid_t

    public var description: String { rawValue.description }
  }
  public let id: ID
}

// MARK: - Logging

public protocol ProcessLogger {
  func failedToLaunchProcess(dueTo error: Error)
  func didLaunch(_ process: Process)
  func willWait(on process: Process)
  func process(_ process: Process, didTerminateWithError: Error?)
}

// MARK: - File Descriptor Mapping

public extension Process {
  
  struct FileDescriptorMapping: ExpressibleByDictionaryLiteral {
    
    public init() {
      self.init(entries: [])
    }
    
    public init(
      standardInput: SystemPackage.FileDescriptor,
      standardOutput: SystemPackage.FileDescriptor,
      standardError: SystemPackage.FileDescriptor,
      additionalFileDescriptors: KeyValuePairs<CInt, SystemPackage.FileDescriptor> = [:]
    ) {
      self.init(entries: [
        (source: standardInput, target: STDIN_FILENO),
        (source: standardOutput, target: STDOUT_FILENO),
        (source: standardError, target: STDERR_FILENO),
      ] + additionalFileDescriptors.map { (source: $0.value, target: $0.key) })
    }
    
    public init(dictionaryLiteral elements: (CInt, SystemPackage.FileDescriptor)...) {
      self.init(entries: elements.map { (source: $0.1, target: $0.0) })
    }
    
    public mutating func addMapping(
      from source: SystemPackage.FileDescriptor,
      to target: CInt
    ) {
      precondition(!entries.contains(where: { $0.target == target }))
      entries.append((source: source, target: target))
    }
    
    private init(entries: [Entry]) {
      /// Ensure each file descriptor is only mapped to once
      precondition(Set(entries.map(\.target)).count == entries.count)
      self.entries = entries
    }
    fileprivate typealias Entry = (source: SystemPackage.FileDescriptor, target: CInt)
    fileprivate private(set) var entries: [Entry]
  }
  
}

// MARK: - Errors

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
     A non-blocking wait was attempted before the process completed
     */
    case processIsStillRunning

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

// MARK: - File Descriptor Monitor

private struct FileDescriptorMonitor {
  /**
    The descriptor being monitored. `monitorFileDescriptor` will wait on this descriptor an any duplicates to close before returning.
    */
  let descriptor: SystemPackage.FileDescriptor
  
  /**
    A closure which runs if the task is cancelled before `monitorFileDescriptor` returns
    */
  var cancellationHandler: (() -> Void)?
}
  
private extension Context {
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
        try await NIOPipeBootstrap(group: eventLoopGroup)
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
