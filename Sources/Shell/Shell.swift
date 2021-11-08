import SystemPackage
@_implementationOnly import NIO
@_implementationOnly import _NIOConcurrency

/// `FilePath` is used extensively in the API so we export it
@_exported import struct SystemPackage.FilePath

public struct Shell {
  public let workingDirectory: FilePath
  public let environment: [String: String]
  
  public init(
    workingDirectory: FilePath,
    environment: [String: String],
    standardInput: Input,
    standardOutput: Output,
    standardError: Output,
    logger: ShellLogger? = nil)
  {
    self.workingDirectory = workingDirectory
    self.environment = environment
    self.standardInput = standardInput
    self.standardOutput = standardOutput
    self.standardError = standardError
    self.nioContext = NIOContext()
    self.logger = logger
  }
  
  public func subshell(
    pushing path: FilePath? = nil,
    replacingEnvironmentWith newEnvironment: [String: String]? = nil,
    standardInput: Input? = nil,
    standardOutput: Output? = nil,
    standardError: Output? = nil
  ) -> Shell {
    return Shell(
      workingDirectory: path.map(workingDirectory.pushing) ?? workingDirectory,
      environment: newEnvironment ?? environment,
      standardInput: standardInput ?? self.standardInput,
      standardOutput: standardOutput ?? self.standardOutput,
      standardError: standardError ?? self.standardError,
      nioContext: nioContext,
      logger: logger)
  }
  
  private init(
    workingDirectory: FilePath,
    environment: [String: String],
    standardInput: Input,
    standardOutput: Output,
    standardError: Output,
    nioContext: NIOContext,
    logger: ShellLogger?)
  {
    self.workingDirectory = workingDirectory
    self.environment = environment
    self.standardInput = standardInput
    self.standardOutput = standardOutput
    self.standardError = standardError
    self.nioContext = nioContext
    self.logger = logger
  }

  private let standardInput: Input
  private let standardOutput: Output
  private let standardError: Output
  let nioContext: NIOContext
  let logger: ShellLogger?
}

// MARK: - IO

extension Shell {
  
  public struct Input {
    
    public static let standardInput = Input(kind: .standardInput)
    
    /**
     An input roughly analogous to using the null device (`/dev/null`).
     */
    public static let nullDevice = Input(kind: .nullDevice)

    static func unmanaged(_ fileDescriptor: FileDescriptor) -> Input {
      Input(kind: .unmanaged(fileDescriptor))
    }
    
    fileprivate enum Kind {
      case standardInput
      case nullDevice
      case unmanaged(FileDescriptor)
    }
    fileprivate let kind: Kind
  }
  
  public struct Output {
    
    public static let standardOutput = Output(kind: .standardOutput)
    
    public static let standardError = Output(kind: .standardError)
    
    public static let nullDevice = Output(kind: .nullDevice)

    static func unmanaged(_ fileDescriptor: FileDescriptor) -> Output {
      Output(kind: .unmanaged(fileDescriptor))
    }
    
    fileprivate enum Kind {
      case standardOutput
      case standardError
      case nullDevice
      case unmanaged(FileDescriptor)
    }
    fileprivate let kind: Kind
  }

  struct IO {
    let standardInput: FileDescriptor
    let standardOutput: FileDescriptor
    let standardError: FileDescriptor
  }

  func withIO<T>(
    _ operation: (IO) async throws -> T
  ) async throws -> T {
    try await withFileDescriptor(for: standardInput) { standardInput in
      try await withFileDescriptor(for: standardOutput) { standardOutput in
        try await withFileDescriptor(for: standardError) { standardError in
          let io = IO(
            standardInput: standardInput,
            standardOutput: standardOutput,
            standardError: standardError)
          return try await operation(io)
        }
      }
    }
  }
  
  func withNullInputDevice<T>(
    _ operation: (FileDescriptor) async throws -> T
  ) async throws -> T {
    try await withFileDescriptor(for: Input.nullDevice, operation)
  }
  
  func withNullOutputDevice<T>(
    operation: (FileDescriptor) async throws -> T
  ) async throws -> T {
    try await nioContext.withNullOutputDevice(operation)
  }
  
  private func withFileDescriptor<T>(
    for input: Input,
    _ operation: (FileDescriptor) async throws -> T
  ) async throws -> T {
    switch input.kind {
    case .standardInput:
      return try await operation(.standardInput)
    case .nullDevice:
      /**
       - note: In actuality, this is implemented as a half-closed pipe. The problem with using something like `FileDescriptor.open("/dev/null", .readOnly)` is that NIO on Linux uses `epoll` to read from file descriptors, and `epoll` is not compatible with `/dev/null`. We use NIO to implement builtins, so we need this descriptor to be compatible with that implementation.
       */
      let pipe = try FileDescriptor.pipe()
      do {
        try pipe.writeEnd.close()
      } catch {
        try! pipe.readEnd.close()
        throw error
      }
      return try await pipe.readEnd.closeAfter {
        try await operation(pipe.readEnd)
      }
    case .unmanaged(let fileDescriptor):
      return try await operation(fileDescriptor)
    }
  }
  
  private func withFileDescriptor<T>(
    for output: Output,
    _ operation: (FileDescriptor) async throws -> T
  ) async throws -> T {
    switch output.kind {
    case .standardOutput:
      return try await operation(.standardOutput)
    case .standardError:
      return try await operation(.standardError)
    case .nullDevice:
      return try await nioContext.withNullOutputDevice(operation)
    case .unmanaged(let fileDescriptor):
      return try await operation(fileDescriptor)
    }
  }

}

// MARK: - Logging

public protocol ShellLogger {
  
  func willLaunch(
    _ executable: Executable,
    withArguments arguments: [String],
    in workingDirectory: FilePath)
  
  func process(
    _ process: Shell.Process,
    didLaunchWith executable: Executable,
    arguments: [String],
    in workingDirectory: FilePath)

  func process(
    _ process: Shell.Process,
    for executable: Executable,
    withArguments arguments: [String],
    in workingDirectory: FilePath,
    didComplete error: Error?)
  
}

extension ShellLogger {
  
  public func willLaunch(
    _ executable: Executable,
    withArguments arguments: [String],
    in workingDirectory: FilePath
  ) {
    
  }
  
  public func process(
    _ process: Shell.Process,
    didLaunchWith executable: Executable,
    arguments: [String],
    in workingDirectory: FilePath
  ) {
    
  }

  public func process(
    _ process: Shell.Process,
    for executable: Executable,
    withArguments arguments: [String],
    in workingDirectory: FilePath,
    didComplete error: Error?
  ) {
    
  }
  
}

// MARK: - NIO Context

actor NIOContext {
  nonisolated let eventLoopGroup: EventLoopGroup
  nonisolated let fileIO: NonBlockingFileIO
  private let threadPool: NIOThreadPool
  
  fileprivate init() {
    eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    threadPool = NIOThreadPool(numberOfThreads: 6)
    threadPool.start()
    fileIO = NonBlockingFileIO(threadPool: threadPool)
  }
  deinit {
    eventLoopGroup.shutdownGracefully { error in
      precondition(error == nil)
    }
    threadPool.shutdownGracefully { error in
      precondition(error == nil)
    }
  }
  
  /**
   - note: In actuality, the null device is implemented as a pipe which discards anything written to it's write end. The problem with using something like `FileDescriptor.open("/dev/null", .writeOnly)` is that NIO on Linux uses `epoll` to read from file descriptors, and `epoll` is incompatible with `/dev/null`.
   */
  fileprivate func withNullOutputDevice<T>(
    _ operation: (FileDescriptor) async throws -> T
  ) async throws -> T {
    let device: NullOutputDevice
    if let existing = nullOutputDevice {
      device = existing
    } else {
      device = try await NullOutputDevice(group: eventLoopGroup)
      nullOutputDevice = device
    }
    /// `device` is guaranteed to be valid for the duration of `operation` because `self` holds a strong reference to it.
    return try await operation(device.fileDescriptor)
  }

  private final class NullOutputDevice {
    let fileDescriptor: FileDescriptor
    let channel: Channel
    init(group: EventLoopGroup) async throws {
      (fileDescriptor, channel) = try await FileDescriptor.withPipe { pipe in
        let channel = try await NIOPipeBootstrap(group: group)
          .channelInitializer { channel in
            final class Handler: ChannelInboundHandler {
              typealias InboundIn = ByteBuffer
              func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                /// Ignore
              }
            }
            return channel.pipeline.addHandler(Handler())
          }
          .duplicating(
            inputDescriptor: pipe.readEnd,
            /**
              We use the write end of the pipe because we need to specify _something_ as the channel output. This file descriptor should never be written to.
              */
            outputDescriptor: pipe.writeEnd)
        return (try pipe.writeEnd.duplicate(), channel)
      }
    }
    deinit {
      try! fileDescriptor.close()
    }
  }
  private var nullOutputDevice: NullOutputDevice?
}
