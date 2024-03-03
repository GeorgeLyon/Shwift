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

/**
 A value which represents a child process
 */
public struct Process {

  /**
   Runs an executable in a separate process, returns once that process terminates.
   */
  public static func run(
    executablePath: FilePath,
    arguments: [String],
    environment: Environment,
    workingDirectory: FilePath,
    fileDescriptorMapping: FileDescriptorMapping,
    logger: ProcessLogger? = nil,
    in context: Context
  ) async throws {
    try await launch(
      executablePath: executablePath,
      arguments: arguments,
      environment: environment,
      workingDirectory: workingDirectory,
      fileDescriptorMapping: fileDescriptorMapping,
      logger: logger,
      in: context
    )
    .value
  }

  /**
   Runs an executable in a separate process, and returns once that process has been launched.
   - Returns: A task which represents the running of the external process.
   */
  public static func launch(
    executablePath: FilePath,
    arguments: [String],
    environment: Environment,
    workingDirectory: FilePath,
    fileDescriptorMapping: FileDescriptorMapping,
    logger: ProcessLogger? = nil,
    in context: Context
  ) async throws -> Task<Void, Error> {
    let process: Process
    let monitor: FileDescriptorMonitor
    (process, monitor) = try await FileDescriptorMonitor.create(in: context) {
      monitoredDescriptor in
      do {
        var fileDescriptorMapping = fileDescriptorMapping
        /// Map the monitored descriptor to the lowest unmapped target descriptor
        let mappedFileDescriptors = Set(fileDescriptorMapping.entries.map(\.target))
        fileDescriptorMapping.addMapping(
          from: monitoredDescriptor,
          to: (0...).first(where: { !mappedFileDescriptors.contains($0) })!)
        let process = try await Process(
          executablePath: executablePath,
          arguments: arguments,
          environment: environment,
          workingDirectory: workingDirectory,
          fileDescriptorMapping: fileDescriptorMapping,
          context: context)
        logger?.didLaunch(process)
        return process
      } catch {
        logger?.failedToLaunchProcess(dueTo: error)
        throw error
      }
    }
    return Task {
      try await withTaskCancellationHandler {
        try await monitor.wait()
        logger?.willWait(on: process)
        do {
          try await process.wait(in: context)
          logger?.process(process, didTerminateWithError: nil)
        } catch {
          logger?.process(process, didTerminateWithError: error)
          throw error
        }
      } onCancel: {
        process.terminate()
      }
    }
  }

  private init(
    executablePath: FilePath,
    arguments: [String],
    environment: Environment,
    workingDirectory: FilePath,
    fileDescriptorMapping: FileDescriptorMapping,
    context: Context
  ) async throws {
    #if true || canImport(Darwin)
      var attributes = try PosixSpawn.Attributes()
      defer { try! attributes.destroy() }
      #if canImport(Darwin)
        try attributes.setFlags([
          .closeFileDescriptorsByDefault,
          .setSignalMask,
        ])
      #else
        try attributes.setFlags([
          .setSignalMask
        ])
      #endif
      try attributes.setBlockedSignals(to: .none)

      var actions = try PosixSpawn.FileActions()
      defer { try! actions.destroy() }
      try actions.addChangeDirectory(to: workingDirectory)
      for entry in fileDescriptorMapping.entries {
        try actions.addDuplicate(entry.source, as: entry.target)
      }
      try actions.addCloseFileDescriptors(from: 100)

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
          ShwiftSpawnInvocationAddFileDescriptorMapping(
            invocation, entry.source.rawValue, entry.target)
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

        let id: Process.ID
        let monitor: FileDescriptorMonitor
        (id, monitor) = try! await FileDescriptorMonitor.create(in: context) {
          monitoredDescriptor in
          ID(rawValue: ShwiftSpawnInvocationLaunch(invocation, monitoredDescriptor.rawValue))!
        }
        try! await monitor.wait()
        return id
      }()
      var failure = ShwiftSpawnInvocationFailure()
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
  private func wait(in context: Context) async throws {
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
    while true {
      /**
       We use a process ID of `0` to detect the case when the child is not in a waitable state.
       Since we use the control channel to detect termination, this _shouldn't_ happen (unless the child decides to call `close(3)` for some reason).
       */
      info[keyPath: pid] = 0
      do {
        errno = 0
        var flags = WEXITED | WNOHANG
        #if canImport(Glibc)
          flags |= __WALL
        #endif
        let returnValue = waitid(P_PID, id_t(id.rawValue), &info, flags)
        guard returnValue == 0 else {
          throw TerminationError.waitFailed(returnValue: returnValue, errno: errno)
        }
      }
      /**
       By monitoring a file descriptor to detect when a process has terminated, we introduce the possibility of performing a nonblocking wait on a process before it is actually ready to be waited on. This can happen if we win the race with the kernel setting the child process into a waitable state after the kernel closes the file descriptor we are monitoring (this is rare, but has been observed and should only ever result in a 1 second delay). This could also be caused by unusual behavior in the child process (for instance, iterating over all of its own descriptors and closing the ones it doesn't know about, including the one we use for monitoring; in this case the overhead of polling should still be minimal).
       */
      guard info[keyPath: pid] != 0 else {
        /// Reset `info`
        info = siginfo_t()
        /// Wait for 1 second (we can't use `Task.sleep` because we want to wait on the child process even if it was cancelled)
        let _: Void = await withCheckedContinuation { continuation in
          context.eventLoopGroup.next().scheduleTask(in: .seconds(1)) {
            continuation.resume()
          }
        }
        /// Try `wait` again
        continue
      }
      /// If we reached this point, the process was successfully waited on
      break
    }

    /**
     If the task has been cancelled, we want cancellation to supercede the temination status of the executable (often a SIGTERM).
     */
    try Task.checkCancellation()

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
      self.init(
        entries: [
          (source: standardInput, target: STDIN_FILENO),
          (source: standardOutput, target: STDOUT_FILENO),
          (source: standardError, target: STDERR_FILENO),
        ] + additionalFileDescriptors.map { (source: $0.value, target: $0.key) })
    }

    public init(dictionaryLiteral elements: (CInt, SystemPackage.FileDescriptor)...) {
      self.init(entries: elements.map { (source: $0.1, target: $0.0) })
    }

    private init(entries: [Entry]) {
      /// Ensure each file descriptor is only mapped to once
      precondition(Set(entries.map(\.target)).count == entries.count)
      self.entries = entries
    }

    public mutating func addMapping(
      from source: SystemPackage.FileDescriptor,
      to target: CInt
    ) {
      precondition(!entries.contains(where: { $0.target == target }))
      entries.append((source: source, target: target))
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

  static func create<T>(
    in context: Context,
    _ forwardMonitoredDescriptor: (SystemPackage.FileDescriptor) async throws -> T
  ) async throws -> (outcome: T, monitor: FileDescriptorMonitor) {
    let future: EventLoopFuture<Void>
    let outcome: T
    (future, outcome) = try await FileDescriptor.withPipe { pipe in
      let channel = try await context.withNullOutputDevice { nullOutput in
        try await NIOPipeBootstrap(group: context.eventLoopGroup)
          .channelInitializer { channel in
            channel.pipeline.addHandler(Handler())
          }
          .duplicating(
            inputDescriptor: pipe.readEnd,
            outputDescriptor: nullOutput)
      }
      let outcome = try await forwardMonitoredDescriptor(pipe.writeEnd)
      return (channel.closeFuture, outcome)
    }
    return (outcome, FileDescriptorMonitor(future: future))
  }

  func wait() async throws {
    try await future.get()
  }

  private let future: EventLoopFuture<Void>

  private final class Handler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
      /**
       Writing data on the monitor descriptor is probably an error. In the future we might want to make incoming data cancel the invocation.
       */
      assertionFailure()
    }
  }
}
