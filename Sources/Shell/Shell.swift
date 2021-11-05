import SystemPackage
@_implementationOnly import NIO
@_implementationOnly import _NIOConcurrency

public struct Shell {
  public let workingDirectory: FilePath
  public let environment: [String: String]
  
  public init(
    workingDirectory: FilePath,
    environment: [String: String],
    standardInput: Input,
    standardOutput: Output,
    standardError: Output)
  {
    self.workingDirectory = workingDirectory
    self.environment = environment
    self.standardInput = standardInput
    self.standardOutput = standardOutput
    self.standardError = standardError
    self.nioContext = NIOContext()
  }

  init(
    workingDirectory: FilePath,
    environment: [String: String],
    standardInput: Input,
    standardOutput: Output,
    standardError: Output,
    nioContext: NIOContext)
  {
    self.workingDirectory = workingDirectory
    self.environment = environment
    self.standardInput = standardInput
    self.standardOutput = standardOutput
    self.standardError = standardError
    self.nioContext = nioContext
  }

  let standardInput: Input
  let standardOutput: Output
  let standardError: Output
  let nioContext: NIOContext
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

  struct Invocation {
    let standardInput: FileDescriptor
    let standardOutput: FileDescriptor
    let standardError: FileDescriptor
    
    /**
     The invocation will wait on this file descriptor to close before it completes. An invocation's lifetime can be extended by, for instance, passing a duplicate of this descriptor to a child process.
     */
    let monitor: FileDescriptor

    /**
     A closure which runs if the task is cancelled before the output and error channels are closed.
     */
    var cancellationHandler: (() -> Void)?

    /**
     A task which will be run if `command` returns successfully after the invocation outputs have closed.
     */
    var cleanupTask: (() throws -> Void)?

  }

  func invoke<T>(
    _ command: (inout Invocation) async throws -> T
  ) async throws -> T {
    try await withFileDescriptor(for: \.standardInput) { standardInput in
      try await withFileDescriptor(for: \.standardOutput) { standardOutput in
        try await withFileDescriptor(for: \.standardError) { standardError in
          let future: EventLoopFuture<T>
          /// This value should only be used to call callbacks installed by `command`
          let unsafeInvocation: Invocation
          (future, unsafeInvocation) = try await FileDescriptor.withPipe { monitorPipe in
            try await nioContext.withNullOutputDevice { nullOutputDevice in
              let channel = try await NIOPipeBootstrap(group: nioContext.eventLoopGroup)
                .channelInitializer { channel in
                  channel.pipeline.addHandler(MonitorHandler())
                }
                .duplicating(
                  inputDescriptor: monitorPipe.readEnd,
                  outputDescriptor: nullOutputDevice)
              var invocation = Invocation(
                standardInput: standardInput, 
                standardOutput: standardOutput,
                standardError: standardError,
                monitor: monitorPipe.writeEnd)
              let outcome = try await command(&invocation)
              let future = channel.closeFuture.map { _ in outcome }
              return (future, invocation)
            }
          }
          let outcome: T
          do {
            /// `closeFuture` can only be awaited on after `withPipe` returns, closing the temporary descriptors.
            outcome = try await withTaskCancellationHandler(
              handler: {
                unsafeInvocation.cancellationHandler?()
              }, 
              operation: {
                try await future.get()
              })
          } catch {
            try unsafeInvocation.cleanupTask?()
            throw error
          }
          try unsafeInvocation.cleanupTask?()
          return outcome
        }
      }
    }
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
  
  private func withFileDescriptor<T>(
    for input: KeyPath<Shell, Input>,
    _ operation: (FileDescriptor) async throws -> T
  ) async throws -> T {
    switch self[keyPath: input].kind {
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
    for output: KeyPath<Shell, Output>,
    _ operation: (FileDescriptor) async throws -> T
  ) async throws -> T {
    switch self[keyPath: output].kind {
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

// MARK: - NIO Context

actor NIOContext {
  nonisolated let eventLoopGroup: EventLoopGroup
  
  fileprivate init() {
    eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  }
  deinit {
    eventLoopGroup.shutdownGracefully { error in
      precondition(error == nil)
    }
  }
  
  /**
   - note: In actuality, the null device is implemented as a pipe which discards anything written to it's write end. The problem with using something like `FileDescriptor.open("/dev/null", .writeOnly)` is that NIO on Linux uses `epoll` to read from file descriptors, and `epoll` is incompatible with `/dev/null`.
   */
  func withNullOutputDevice<T>(
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
