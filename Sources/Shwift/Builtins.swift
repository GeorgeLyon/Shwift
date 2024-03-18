@_implementationOnly import NIO
import SystemPackage
@_implementationOnly import _NIOConcurrency

/**
 A namespace for types involved in executing builtins
 */
public enum Builtin {

  public struct Channel {
    public let input: Input
    public let output: Output
  }
  public static func withChannel<T>(
    input: SystemPackage.FileDescriptor,
    output: SystemPackage.FileDescriptor,
    in context: Context,
    _ operation: (Channel) async throws -> T,
    file: StaticString = #fileID, line: UInt = #line
  ) async throws -> T {
    let handler = AsyncInboundHandler<ByteBuffer>()
    let nioChannel = try await NIOPipeBootstrap(group: context.eventLoopGroup)
      .channelOption(ChannelOptions.autoRead, value: false)
      .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
      .channelInitializer { channel in
        /**
         Theoretically if we add this before a call to `channel.read`, it _should_ receive all data sent on the channel. Unfortunately we ran into a case where on Linux, adding the handler outside of the channel initializer made us miss some data.
         */
        return channel.pipeline.addHandler(handler)
      }
      .duplicating(
        inputDescriptor: input,
        outputDescriptor: output)
    let inputBuffers =
      try! handler
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
    let channel = Channel(
      input: Input(byteBuffers: inputBuffers),
      output: Output(channel: nioChannel))
    let result: Result<T, Error>
    do {
      result = .success(try await operation(channel))
    } catch {
      result = .failure(error)
    }
    do {
      try await nioChannel.close()
    } catch ChannelError.alreadyClosed {
      /**
       I'm not sure why, but closing the channel occasionally throws an unexpected `alreadyClosed` error. We should get to the bottom of this, but in the meantime we can suppress this ostensibly benign error.
       */
      print("\(file):\(line): Received unexpected alreadyClosed")
    }
    return try result.get()
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
                while let lineBreak = substring.firstIndex(of: delimiter) {
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
      fileprivate let delimiter: Character
    }

    /// Make a Lines iterator splitting at newlines
    public var lines: Lines {
      segmented()
    }

    /// Make a Lines iterator yielding text segments between delimiters (like split).
    ///
    /// - Parameter delimiter: Character separating input text to yield (and not itself yielded)  Defaults to newline.
    /// - Returns: Lines segmented by delimiter
    public func segmented(by delimiter: Character = "\n") -> Lines {
      Lines(byteBuffers: byteBuffers, delimiter: delimiter)
    }

    typealias ByteBuffers = AsyncCompactMapSequence<
      AsyncPrefixWhileSequence<AsyncInboundHandler<ByteBuffer>>, ByteBuffer
    >
    let byteBuffers: ByteBuffers
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
      fileprivate let channel: NIO.Channel
      fileprivate var lastFuture: EventLoopFuture<Void>?
    }

    fileprivate let channel: NIO.Channel
  }

}

// MARK: - File IO

/**
 The core `Shell` library provides only two builtins: `read` and `write` for reading from and writing to files, respectively. We provide these because they are extremely fundamental functionality for shells and we can implement them using `NIO` without exposing this dependency to higher level frameworks. Other builtins should be implemented in higher level frameworks, like `Script` to avoid having duplicate APIs on `Shell`.
 */
extension Builtin {

  public static func read(
    from filePath: FilePath,
    to output: SystemPackage.FileDescriptor,
    in context: Context
  ) async throws {
    precondition(filePath.isAbsolute)
    try await Shwift.Input.nullDevice.withFileDescriptor(in: context) { nullDeviceInput in
      try await withChannel(input: nullDeviceInput, output: output, in: context) { channel in
        let output = channel.output
        let eventLoop = output.channel.eventLoop
        let fileHandle = try await context.fileIO.openFile(
          path: filePath.string,
          mode: .read,
          eventLoop: eventLoop
        )
        .get()
        let result: Result<Void, Error>
        do {
          result = .success(
            try await context.fileIO
              .readChunked(
                fileHandle: fileHandle,
                byteCount: .max,
                allocator: output.channel.allocator,
                eventLoop: eventLoop,
                chunkHandler: { buffer in
                  output.channel.writeAndFlush(buffer)
                }
              )
              .get())
        } catch {
          result = .failure(error)
        }
        try fileHandle.close()
        try result.get()
      }
    }
  }

  /**
   Write this shell's `input` to the specified file, creating it if necessary.
   */
  public static func write(
    _ input: SystemPackage.FileDescriptor,
    to filePath: FilePath,
    append: Bool = false,
    in context: Context
  ) async throws {
    precondition(filePath.isAbsolute)
    try await Shwift.Output.nullDevice.withFileDescriptor(in: context) { nullDeviceOutput in
      try await withChannel(input: input, output: nullDeviceOutput, in: context) { channel in
        let eventLoop = context.eventLoopGroup.next()
        let fileHandle = try await context.fileIO.openFile(
          path: filePath.string,
          mode: .write,
          flags: .posix(
            flags: O_CREAT | (append ? O_APPEND : O_TRUNC),
            mode: S_IWUSR | S_IRUSR | S_IRGRP | S_IROTH),
          eventLoop: eventLoop
        )
        .get()
        let result: Result<Void, Error>
        do {
          for try await buffer in channel.input.byteBuffers {
            try await context.fileIO.write(
              fileHandle: fileHandle,
              buffer: buffer,
              eventLoop: eventLoop
            )
            .get()
          }
          result = .success(())
        } catch {
          result = .failure(error)
        }
        try fileHandle.close()
        try result.get()
      }
    }
  }

}
