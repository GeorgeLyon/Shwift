import SystemPackage
@_implementationOnly import NIO
@_implementationOnly import _NIOConcurrency

public struct Shell {
  public let workingDirectory: FilePath
  public let environment: [String: String]
  public let standardInput: Input
  public let standardOutput: Output
  public let standardError: Output
  
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
  
  let nioContext: NIOContext
}

// MARK: - Invocation

extension Shell {
  
  struct InternalRepresentation {
    let workingDirectory: FilePath
    let environment: [String: String]
    let standardInput: FileDescriptor
    let standardOutput: FileDescriptor
    let standardError: FileDescriptor
    let nioContext: NIOContext
  }
  
  func invoke<T>(
    operation: (InternalRepresentation) async throws -> T
  ) async throws -> T {
    try await withFileDescriptor(for: standardInput) { standardInput in
      try await withFileDescriptor(for: standardOutput) { standardOutput in
        try await withFileDescriptor(for: standardError) { standardError in
          let shell = InternalRepresentation(
            workingDirectory: workingDirectory,
            environment: environment,
            standardInput: standardInput,
            standardOutput: standardOutput,
            standardError: standardError,
            nioContext: nioContext)
          return try await operation(shell)
        }
      }
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
              func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
                print("EVENT: \(event)")
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
