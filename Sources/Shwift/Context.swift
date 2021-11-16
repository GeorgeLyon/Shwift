
@_implementationOnly import NIO

import SystemPackage

public final class Context {
  let eventLoopGroup: EventLoopGroup
  let fileIO: NonBlockingFileIO
  private let threadPool: NIOThreadPool
  private let nullOutputDevice = NullOutputDevice()
  
  public init() {
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
  func withNullOutputDevice<T>(
    _ operation: (SystemPackage.FileDescriptor) async throws -> T
  ) async throws -> T {
    /**
     The file descriptor is guaranteed to be valid since we maintain a strong reference to `nullOutputDevice` for the duration of `operation`.
     */
    return try await operation(nullOutputDevice.fileDescriptor(with: eventLoopGroup))
  }
}

// MARK: - Support

private actor NullOutputDevice {
  /**
    - Returns: A file descriptor which is guaranteed to be valid as long as the callee is valid
    */
  func fileDescriptor(with group: EventLoopGroup) async throws -> SystemPackage.FileDescriptor {
    if let (_, fileDescriptor) = state {
      return fileDescriptor
    } else {
      let channel: Channel
      let fileDescriptor: SystemPackage.FileDescriptor
      (channel, fileDescriptor) =  try await SystemPackage.FileDescriptor.withPipe { pipe in
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
        let fileDescriptor = try pipe.writeEnd.duplicate()
        return (channel, fileDescriptor)
      }
      state = (channel, fileDescriptor)
      return fileDescriptor
    }
  }

  deinit {
    if let (_, fileDescriptor) = state {
      try! fileDescriptor.close()
      /// `channel` should be automatically closed by the event loop group being closed
    }
  }

  private var state: (channel: Channel, fileDescriptor: SystemPackage.FileDescriptor)?
}
