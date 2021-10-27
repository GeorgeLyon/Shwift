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
  
  struct State {
    let workingDirectory: FilePath
    let environment: [String: String]
    let standardInput: FileDescriptor
    let standardOutput: FileDescriptor
    let standardError: FileDescriptor
    let nioContext: NIOContext
  }
  
  func invoke<T>(
    operation: (State) async throws -> T
  ) async throws -> T {
    try await standardInput.withFileDescriptor { standardInput in
      try await standardOutput.withFileDescriptor { standardOutput in
        try await standardError.withFileDescriptor { standardError in
          let state = State(
            workingDirectory: workingDirectory,
            environment: environment,
            standardInput: standardInput,
            standardOutput: standardOutput,
            standardError: standardError,
            nioContext: nioContext)
          return try await operation(state)
        }
      }
    }
  }
}

// MARK: - NIO Context

final class NIOContext {
  let eventLoopGroup: EventLoopGroup
  
  fileprivate init() {
    eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  }
  deinit {
    eventLoopGroup.shutdownGracefully { error in
      precondition(error == nil)
    }
  }
}

// MARK: - Support

private final class ControlChannelHandler: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    fatalError()
  }
}
