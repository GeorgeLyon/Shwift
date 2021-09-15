
import NIO
import NIOExtras
import _NIOConcurrency
import SystemPackage
import class Foundation.DispatchQueue

/**
 - note: The core `Shell` library provides only two builtins: `read` and `write` for reading from and writing to files, respectively. We provide these because they are extremely fundamental functionality for shells and we can implement them using `NIO` without exposing this dependency to higher level frameworks. Other builtins should be implemented in higher level frameworks, like `Script` to avoid having duplicate APIs on `Shell`.
 */


extension Shell {
  
  /**
   Executes the provided builtin
   */
  public func builtin<T>(_ body: (inout Builtin.Handle) async throws -> T) async throws -> T {
    let bootstrap = NIOPipeBootstrap(group: builtinContext.eventLoopGroup)
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
    
    let results: [Result<T, Error>]
    do {
      var handle = Builtin.Handle(
        input: Builtin.Input(channel: io),
        output: Builtin.Output(channel: io),
        error: Builtin.Output(channel: error))
      let result: Result<T, Error>
      do {
        result = .success(try await body(&handle))
      } catch {
        result = .failure(error)
      }
      results = handle.cleanupTasks.compactMap { task in
        do {
          try task()
          return nil
        } catch {
          return .failure(error)
        }
      } + [result]
    }
    
    /// We want to attempt to close both channels even if the first one fails
    for future in [io, error].map({ $0.close(mode: .all) }) {
      try await future.get()
    }
    
    /// We may eventually want to report additional errors from cleanup tasks
    return try results.first!.get()
  }
  
  /**
   Push the contents of a file to this shell's `output`
   */
  func read(from filePath: FilePath) async throws {
    try await builtin { handle in
      let eventLoop = builtinContext.eventLoopGroup.next()
      let (fileHandle, region) = try await builtinContext.fileIO.openFile(
        path: directory.pushing(filePath).string,
        eventLoop: eventLoop)
        .get()
      handle.addCleanupTask { try fileHandle.close() }
      try await builtinContext.fileIO.readChunked(
        fileRegion: region,
        allocator: handle.output.channel.allocator,
        eventLoop: eventLoop,
        chunkHandler: handle.output.channel.writeAndFlush)
        .get()
    }
  }
  
  /**
   Write this shell's `input` to the specified file
   */
  func write(
    to filePath: FilePath,
    openOptions: SystemPackage.FileDescriptor.OpenOptions = []) async throws {
    try await builtin { handle in
      let eventLoop = builtinContext.eventLoopGroup.next()
      let fileHandle = try await builtinContext.fileIO.openFile(
        path: directory.pushing(filePath).string,
        mode: .write,
        flags: .posix(flags: openOptions.rawValue, mode: 0),
        eventLoop: eventLoop)
        .get()
      handle.addCleanupTask { try fileHandle.close() }
      for try await buffer in handle.input.byteBuffers {
        try await builtinContext.fileIO.write(
          fileHandle: fileHandle,
          buffer: buffer,
          eventLoop: eventLoop)
          .get()
      }
    }
  }
}

/**
 A namespace for types related to providing builtin operations for `Shell`
 */
public enum Builtin {
  
}

// MARK: - IO


extension Builtin {
  
  /**
   A type used to implement the behavior of a builtin operation
   */
  public struct Handle {
    public let input: Input
    public let output: Output
    public let error: Output
    
    public typealias CleanupTask = () throws -> Void
    public mutating func addCleanupTask(_ task: @escaping CleanupTask) {
      cleanupTasks.append(task)
    }
    fileprivate var cleanupTasks: [CleanupTask] = []
  }
  
  /**
   A type offering different ways to interpret the input of a shell command
   
   - warning: Shell input is a non-replayable stream, so while we hope to eventually offer many different way to process input, any specific shell command should only ever process it _once_. We enforce this at runtime, and mark the relevant methods as `__consuming`, which currently does nothing but will eventually be enforced once the compiler understands move-only types.
   */
  public struct Input {
    
    /**
     Process this input line by line
     */
    public var lines: Strings {
      __consuming get {
        let byteBuffers = ByteBuffers(
          channel: channel,
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
      __consuming get {
        ByteBuffers(channel: channel, preprocessor: nil)
      }
    }
    
    /**
     Iterates over the `ByteBuffer`s yeilded by `Handler`
     */
    struct ByteBuffers: AsyncSequence {
      typealias Element = ByteBuffer
      
      struct AsyncIterator: AsyncIteratorProtocol {
        
        mutating func next() async throws -> ByteBuffer? {
          if case .uninitialized(let task) = state {
            state = .iterating(try await task.result.get().makeAsyncIterator())
          }
          guard case .iterating(var byteBuffers) = state else {
            fatalError()
          }
          defer { state = .iterating(byteBuffers) }
          return try await byteBuffers.next()
        }
        
        fileprivate init(_ operation: @escaping @Sendable () async throws -> _ByteBuffers) {
          state = .uninitialized(Task(operation: operation))
        }
        
        private enum State {
          case uninitialized(Task<_ByteBuffers, Error>)
          case iterating(_ByteBuffers.AsyncIterator)
        }
        private var state: State
      }
      func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator { [channel, preprocessor] in
          try await _ByteBuffers(channel: channel, preprocessor: preprocessor)
        }
      }
      
      fileprivate let channel: Channel
      fileprivate let preprocessor: ChannelHandler?
    }
    
    /**
     Iterates over the `ByteBuffer`s yeilded by `Handler`
     
     This is a private type which relies on the `ChannelHandler` being attached when this type is initialized. An unfortunate consequence of this is that the initializer is `async` so returning sequences based on this type would need to be `async` as well, resulting in unfortunate spellings like `for await line in await input.lines { … }`. To make this a bit nicer, we only expose a wrapper type (`ByteBuffers`) which rolls the asynchronous initialization into the first call to `next`.
     */
    fileprivate struct _ByteBuffers: AsyncSequence, @unchecked Sendable {
      
      init(channel: Channel, preprocessor: ChannelHandler?) async throws {
        self.channel = channel
        
        #if DEBUG
        /// Check that we didn't already register a handler
        let existingHandler = try! await channel.pipeline
          .handler(type: InboundAsyncSequence<ByteBuffer>.self)
          .map { Optional.some($0) }
          .recover { _ in nil }
          .get()
        assert(existingHandler == nil)
        #endif
        
        sequence = InboundAsyncSequence<ByteBuffer>()
        try! await channel.pipeline
          .addHandlers([
            preprocessor,
            sequence,
          ].compactMap { $0 })
          .get()
      }
      
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
                  switch event {
                  case .read(let buffer):
                    return buffer
                  case .error(let error as NIOExtrasErrors.LeftOverBytesError):
                    return error.leftOverBytes
                  default:
                    return nil
                  }
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
    
    let channel: Channel
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
    
    let channel: Channel
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
        eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        threadPool = NIOThreadPool(numberOfThreads: 1)
        fileIO = NonBlockingFileIO(threadPool: threadPool)
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
          assertionFailure()
          Context.queue.sync {
            Context.unhandledErrors.append(contentsOf: errors)
          }
        }
      }
    }
    private static let queue = DispatchQueue(label: #fileID)
    private static weak var sharedStorage: Storage?
    private(set) static var unhandledErrors: [Error] = []
  }
}

// MARK: - Support

private extension SystemPackage.FileDescriptor {
  
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
