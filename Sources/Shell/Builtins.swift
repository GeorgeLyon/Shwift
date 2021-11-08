import Foundation
import SystemPackage

@_implementationOnly import NIO
@_implementationOnly import _NIOConcurrency

public typealias Builtin = Shell.Builtin

extension Shell {

  /**
   A namespace for types involved in executing builtins
   */
  public enum Builtin {

  }

  public func builtin<Outcome>(
    operation: (inout Builtin.Handle) async throws -> Outcome
  ) async throws -> Outcome {
    return try await withIO { io in
      let ioHandler = AsyncInboundHandler<ByteBuffer>()
      let ioChannel = try await NIOPipeBootstrap(group: nioContext.eventLoopGroup)
        .channelOption(ChannelOptions.autoRead, value: false)
        .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
        .channelInitializer { channel in
          /**
           Theoretically if we add this before a call to `channel.read`, it _should_ receive all data sent on the channel. Unfortunately we ran into a case where on Linux, adding the handler outside of the channel initializer made us miss some data.
           */
          return channel.pipeline.addHandler(ioHandler)
        }
        .duplicating(
          inputDescriptor: io.standardInput,
          outputDescriptor: io.standardOutput)
      let inputByteBuffers = try ioHandler
        .prefix(while: { event in
          if case .userInboundEventTriggered(_, ChannelEvent.inputClosed) = event {
            return false
          } else {
            return true
          }
        })
        .compactMap { event -> ByteBuffer? in
          switch event {
          case .handlerAdded(let context):
            /// Call `read` only if we access the byte buffers
            context.eventLoop.execute {
              context.read()
            }
            return nil
          case .channelRead(_, let buffer):
            return buffer
          case .channelReadComplete(let context):
            context.eventLoop.execute {
              context.read()
            }
            return nil
          default:
            return nil
          }
        }
      
      let errorChannel: Channel
      do {
        /**
         NIO does not currently support the creation of half-open channels, so we use the null device as our input.
         More details here: https://github.com/apple/swift-nio/issues/1553
         */
        errorChannel = try await withNullInputDevice { nullInputDevice in
          try await NIOPipeBootstrap(group: nioContext.eventLoopGroup)
            /// Even though we share these options with `ioChannel`, we have to create a new bootstrap since `childChannelInitializer` mutates `self`.
            .channelOption(ChannelOptions.autoRead, value: false)
            .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .duplicating(
              inputDescriptor: nullInputDevice,
              outputDescriptor: io.standardError)
        }
      } catch {
        try! await ioChannel.close().get()
        throw error
      }

      /// We express the following as a closure to ensure we do not throw before we close `io` and `error`
      let results: [Result<Outcome, Error>] = await {
        var results: [Result<Outcome, Error>] = []
        var handle = Builtin.Handle(
          input: Builtin.Input(byteBuffers: inputByteBuffers),
          output: Builtin.Output(channel: ioChannel),
          error: Builtin.Output(channel: errorChannel))

        let result: Result<Outcome, Error>
        do {
          result = .success(try await operation(&handle))
        } catch {
          result = .failure(error)
        }

        for task in handle.cleanupTasks {
          do {
            try await task()
          } catch {
            results.append(.failure(error))
          }
        }

        for channel in [ioChannel, errorChannel] {
          do {
            try await channel.close(mode: .all)
          } catch {
            results.append(.failure(error))
          }
        }

        results.append(result)
        return results
      }()
      
      /**
       Eventually, we may want to report _all_ encountered errors, but for now we only report the first.
       */
      return try results.first!.get()
    }
  }

}

// MARK: - Handle

extension Builtin {

  /**
   A type used to implement the behavior of a builtin operation
   */
  public struct Handle {
    public let input: Input
    public let output: Output
    public let error: Output

    typealias CleanupTask = () async throws -> Void

    /**
     Adds a task to be run after the builtin has completed. All cleanup tasks are run, even if one of them throws an error. If _any_ cleanup task fails, the builtin throws the first such error encountered.

     - note: `defer` isn't great for asynchronous or throwing cleanup tasks, so we provide a convenience mechanism to support this
     */
    mutating func addCleanupTask(_ task: @escaping CleanupTask) {
      cleanupTasks.append(task)
    }
    fileprivate var cleanupTasks: [CleanupTask] = []
  }

}

// MARK: - IO

extension Builtin {

  public struct Input {

    public struct Lines: AsyncSequence {
      public typealias Element = String

      public struct AsyncIterator: AsyncIteratorProtocol {
        public mutating func next() async throws -> String? {
          try await iterator.next()
        }
        fileprivate var iterator: AsyncThrowingStream<String, Error>.AsyncIterator
      }
      public func makeAsyncIterator() -> AsyncIterator {
        let stream = AsyncThrowingStream<String, Error> { continuation in
          Task<Void, Never> {
            do {
              var remainder: String = ""
              for try await buffer in byteBuffers {
                let readString = buffer.getString(
                  at: buffer.readerIndex,
                  length: buffer.readableBytes)!
                var substring = readString[readString.startIndex...]
                while let lineBreak = substring.firstIndex(of: "\n") {
                  let line = substring[substring.startIndex..<lineBreak]
                  substring = substring[substring.index(after: lineBreak)...]
                  continuation.yield(remainder + String(line))
                  remainder = ""
                }
                remainder = String(substring)
              }
              if !remainder.isEmpty {
                continuation.yield(String(remainder))
              }
              continuation.finish()
            } catch {
              continuation.finish(throwing: error)
            }
          }
        }
        return AsyncIterator(iterator: stream.makeAsyncIterator())
      }

      fileprivate let byteBuffers: ByteBuffers
    }
    public var lines: Lines {
      Lines(byteBuffers: byteBuffers)
    }

    fileprivate typealias ByteBuffers = AsyncCompactMapSequence<
      AsyncPrefixWhileSequence<AsyncInboundHandler<ByteBuffer>>, ByteBuffer
    >
    fileprivate let byteBuffers: ByteBuffers
  }

  /**
   A type which can be used to write to a shell command's standard output or standard error
   */
  public struct Output {

    public func withTextOutputStream(_ body: (inout TextOutputStream) -> Void) async throws {
      var stream = TextOutputStream(channel: channel)
      body(&stream)
      channel.flush()
      try await stream.lastFuture?.get()
    }

    public struct TextOutputStream: Swift.TextOutputStream {
      public mutating func write(_ string: String) {
        let buffer = channel.allocator.buffer(string: string)
        /// This future should implicitly be fulfilled after any previous future
        lastFuture = channel.write(NIOAny(buffer))
      }
      fileprivate let channel: Channel
      fileprivate var lastFuture: EventLoopFuture<Void>?
    }

    fileprivate let channel: Channel
  }

}

// MARK: - File IO

/**
 The core `Shell` library provides only two builtins: `read` and `write` for reading from and writing to files, respectively. We provide these because they are extremely fundamental functionality for shells and we can implement them using `NIO` without exposing this dependency to higher level frameworks. Other builtins should be implemented in higher level frameworks, like `Script` to avoid having duplicate APIs on `Shell`.
 */
extension Shell {

  public func read(from filePath: FilePath) async throws {
    try await builtin { handle in
      let output = handle.output
      let eventLoop = output.channel.eventLoop
      let fileHandle = try await nioContext.fileIO.openFile(
        path: workingDirectory.pushing(filePath).string, 
        mode: .read, 
        eventLoop: eventLoop)
        .get()
      handle.addCleanupTask { try fileHandle.close() }
      try await nioContext.fileIO
        .readChunked(
          fileHandle: fileHandle, 
          byteCount: .max,
          allocator: output.channel.allocator, 
          eventLoop: eventLoop, 
          chunkHandler: { buffer in
            output.channel.writeAndFlush(buffer)
          })
        .get()
    }
  }

  /**
   Write this shell's `input` to the specified file, creating it if necessary.
   */
  public func write(
    to filePath: FilePath,
    append: Bool = false
  ) async throws {
    try await builtin { handle in
      let eventLoop = nioContext.eventLoopGroup.next()
      let fileHandle = try await nioContext.fileIO.openFile(
        path: workingDirectory.pushing(filePath).string,
        mode: .write,
        flags: .posix(
          flags: O_CREAT | (append ? O_APPEND : O_TRUNC),
          mode: S_IWUSR | S_IRUSR | S_IRGRP | S_IROTH),
        eventLoop: eventLoop
      )
      .get()
      handle.addCleanupTask { try fileHandle.close() }
      for try await buffer in handle.input.byteBuffers {
        try await nioContext.fileIO.write(
          fileHandle: fileHandle,
          buffer: buffer,
          eventLoop: eventLoop
        )
        .get()
      }
    }
  }

}

// MARK: - Context

extension Builtin {

  /**
   Context in which to execut builtin operations
   */
  struct Context {

    init() {
      storage = Self.queue.sync {
        if let storage = Self.sharedStorage {
          return storage
        } else {
          let storage = Storage()
          Self.sharedStorage = storage
          return storage
        }
      }
    }

    /**
     The returned value is only guaranteed to be valid if the owning `Context` struct is valid (ensuring we maintain a strong reference to `Storage`). As a result, this is only safe to use in the body of the `Shell.builtin` function, since the `Shell` maintains this strong reference.
     */
    fileprivate var fileIO: NonBlockingFileIO {
      storage.fileIO
    }

    /**
     The returned value is only guaranteed to be valid if the owning `Context` struct is valid (ensuring we maintain a strong reference to `Storage`). As a result, this is only safe to use in the body of the `Shell.builtin` function, since the `Shell` maintains this strong reference.
     */
    fileprivate var eventLoopGroup: EventLoopGroup {
      storage.eventLoopGroup
    }

    private let storage: Storage

    /// TODO: Sendable conformance is unchecked until the compiler gets better post Swift 5.5
    private final class Storage: @unchecked Sendable {
      let threadPool: NIOThreadPool
      let eventLoopGroup: MultiThreadedEventLoopGroup
      let fileIO: NonBlockingFileIO

      init() {
        eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 6)
        threadPool = NIOThreadPool(numberOfThreads: 6)
        threadPool.start()
        fileIO = NonBlockingFileIO(threadPool: threadPool)
      }
      deinit {
        try! eventLoopGroup.syncShutdownGracefully()
        try! threadPool.syncShutdownGracefully()
      }
    }
    private static let queue = DispatchQueue(label: #fileID)
    private static weak var sharedStorage: Storage?
  }
}
