
import NIO
import NIOExtras
import _NIOConcurrency
import SystemPackage
import class Foundation.DispatchQueue

extension Shell {
  
  func builtin<T>(_ body: (BuiltinHandle) async throws -> T) async throws -> T {
    let bootstrap = NIOPipeBootstrap(group: builtinEngine.context.eventLoopGroup)
      .channelOption(ChannelOptions.autoRead, value: false)
      .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
    
    let io = try await withFileDescriptor(for: input) { input in
      try await input.duplicateAndTransferOwnership { input in
        try await withFileDescriptor(for: output) { output in
          try await output.duplicateAndTransferOwnership { output in
            try await bootstrap
              .withPipes(
                inputDescriptor: input.rawValue,
                outputDescriptor: output.rawValue)
              .get()
          }
        }
      }
    }
    
    let error: Channel
    do {
      error = try await withFileDescriptor(for: Input.nullDevice) { input in
        try await input.duplicateAndTransferOwnership { input in
          try await withFileDescriptor(for: self.error) { error in
            try await error.duplicateAndTransferOwnership { error in
              try await bootstrap
                .withPipes(
                  inputDescriptor: input.rawValue,
                  outputDescriptor: error.rawValue)
                .get()
            }
          }
        }
      }
    } catch {
      do {
        try await io.close().get()
      } catch let error {
        assertionFailure()
        _ = error
      }
      throw error
    }
    
    let result: Result<T, Error>
    do {
      let handle = BuiltinHandle(
        input: BuiltinHandle.InputStream(channel: io),
        output: BuiltinHandle.OutputStream(channel: io),
        error: BuiltinHandle.OutputStream(channel: error))
      result = .success(try await body(handle))
    } catch {
      result = .failure(error)
    }
    
    /// We want to attempt to close both channels even if the first one fails
    for future in [io, error].map({ $0.close(mode: .all) }) {
      try await future.get()
    }
    
    return try result.get()
  }
  
}

struct BuiltinHandle {
  
  let input: InputStream
  let output: OutputStream
  let error: OutputStream
  
  /**
   A type offering different way to interpret the input of a shell command
   
   - warning: Shell input is a non-replayable stream, so while we hope to eventually offer many different way to process input, any specific shell command should only ever process it _once_. We enforce this at runtime, and mark the relevant methods as `__consuming`, which currently does nothing but will eventually be enforced once the compiler understands move-only types.
   */
  struct InputStream {
    
    /**
     Process this input line by line
     */
    public var lines: Strings {
      __consuming get async {
        let byteBuffers = await byteBuffers(
          preprocessor: ByteToMessageHandler(LineBasedFrameDecoder()))
        return Strings(iterator: byteBuffers.makeAsyncIterator())
      }
    }
    
    /**
     Type which interprets incoming frames as strings.
     */
    public struct Strings: AsyncSequence {
      public typealias Element = String
      
      public struct AsyncIterator: AsyncIteratorProtocol {
        public mutating func next() async throws -> String? {
          try await iterator.next().map(String.init)
        }
        fileprivate var iterator: ByteBuffers.AsyncIterator
      }
      __consuming public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(iterator: iterator)
      }
      fileprivate let iterator: ByteBuffers.AsyncIterator
    }
    
    var byteBuffers: ByteBuffers {
      __consuming get async {
        await byteBuffers(preprocessor: nil)
      }
    }
    
    /**
     Iterates over the `ByteBuffer`s yeilded by `Handler`
     */
    struct ByteBuffers: AsyncSequence {
      typealias Element = ByteBuffer
      
      struct AsyncIterator: AsyncIteratorProtocol {
        mutating func next() async throws -> ByteBuffer? {
          var next: ByteBuffer?
          while next == nil {
            if syncIterator == nil {
              guard let sequenceNext = try await sequence.next() else {
                return nil
              }
              syncIterator = sequenceNext
                .compactMap { event -> ByteBuffer? in
                  guard case let .read(buffer) = event else {
                    return nil
                  }
                  return buffer
                }
                .makeIterator()
            }
            next = syncIterator!.next()
            if next == nil {
              syncIterator = nil
            }
          }
          return next
        }
        
        /// We don't explicitly use `channel` but we do want to keep a reference to it
        fileprivate let channel: Channel
        
        fileprivate var sequence: InboundAsyncSequence<ByteBuffer>.AsyncIterator
        fileprivate var syncIterator: Array<ByteBuffer>.Iterator?
      }
      __consuming func makeAsyncIterator() -> AsyncIterator {
        return AsyncIterator(
          channel: channel,
          sequence: sequence.makeAsyncIterator())
      }
      
      fileprivate let channel: Channel
      fileprivate let sequence: InboundAsyncSequence<ByteBuffer>
    }
    
    __consuming private func byteBuffers(preprocessor: ChannelHandler?) async -> ByteBuffers {
      #if DEBUG
      /// Check that we didn't already register a handler
      let existingHandler = try! await channel.pipeline
        .handler(type: InboundAsyncSequence<ByteBuffer>.self)
        .map { Optional.some($0) }
        .recover { _ in nil }
        .get()
      assert(existingHandler == nil)
      #endif
      
      let sequence = InboundAsyncSequence<ByteBuffer>()
      try! await channel.pipeline
        .addHandlers([
          preprocessor,
          sequence,
        ].compactMap { $0 })
        .get()
      return ByteBuffers(channel: channel, sequence: sequence)
    }
    
    let channel: Channel
  }
  
  /**
   A type which can be used to write to a shell command's standard output or standard error
   */
  struct OutputStream {
    
    let channel: Channel
    
    func withTextOutputStream(_ body: (inout TextOutputStream) -> Void) async throws {
      var stream = TextOutputStream(channel: channel)
      body(&stream)
      channel.flush()
      try await stream.lastFuture?.get()
    }
    
    struct TextOutputStream: Swift.TextOutputStream {
      mutating func write(_ string: String) {
        let buffer = channel.allocator.buffer(string: string)
        /// This future should implicitly be fulfilled after any previous future
        lastFuture = channel.write(NIOAny(buffer))
      }
      fileprivate let channel: Channel
      fileprivate var lastFuture: EventLoopFuture<Void>?
    }
  }

}

// MARK: - Context

struct BuiltinEngine {
  
  fileprivate let context: Context = .shared
  
  fileprivate final class Context: Sendable {
    init() {
      eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
      threadPool = NIOThreadPool(numberOfThreads: 1)
      nonBlockingFileIO = NonBlockingFileIO(threadPool: threadPool)
    }
    deinit {
      var errors: [Error] = []
      do {
        try eventLoopGroup.syncShutdownGracefully()
      } catch {
        errors.append(error)
      }
      do {
        try threadPool.syncShutdownGracefully()
      } catch {
        errors.append(error)
      }
      if !errors.isEmpty {
        Self.report(errors)
      }
    }
    
    let threadPool: NIOThreadPool
    let eventLoopGroup: EventLoopGroup
    let nonBlockingFileIO: NonBlockingFileIO
    
    static var shared: Context {
      queue.sync {
        if let context = _shared {
          return context
        } else {
          let context = Context()
          _shared = context
          return context
        }
      }
    }
    private static weak var _shared: Context?
    
    private static func report(_ unhandledErrors: [Error]) {
      assertionFailure()
      queue.sync {
        self.unhandledErrors.append(contentsOf: unhandledErrors)
      }
    }
    private(set) static var unhandledErrors: [Error] = []
    
    private static let queue = DispatchQueue(label: #fileID)
  }
    
}

// MARK: - Support

extension SystemPackage.FileDescriptor {
  
  /**
   Duplicates the file descriptor and attempts to transfer ownership using the provided block. If ownership transfer fails (throws an error), closes the created duplicate.
   */
  func duplicateAndTransferOwnership<T>(
    _ transferOwnership: (Self) async throws -> T
  ) async throws -> T {
    let dup = try duplicate()
    do {
      return try await transferOwnership(dup)
    } catch {
      do {
        try dup.close()
      } catch let error {
        assertionFailure()
        _ = error
      }
      throw error
    }
  }
}
