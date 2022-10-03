import SystemPackage

/**
 A value representing the input to a shell command
 */
public struct Input {

  /**
   An `Input` corresponding to `stdin`
   */
  public static let standardInput = Input(kind: .standardInput)

  /**
   An input roughly analogous to using the null device (`/dev/null`).
   */
  public static let nullDevice = Input(kind: .nullDevice)

  /**
   An input backed by an unmanaged file descriptor. It is the caller's responsibility to ensure that this file descriptor remains valid for as long as this input is in use.
   */
  public static func unmanaged(_ fileDescriptor: SystemPackage.FileDescriptor) -> Input {
    Input(kind: .unmanaged(fileDescriptor))
  }

  /**
   Creates a file descriptor for this `Input` which will be valid for the duration of `operation`.
   */
  public func withFileDescriptor<T>(
    in context: Context,
    _ operation: (SystemPackage.FileDescriptor) async throws -> T
  ) async throws -> T {
    switch kind {
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

  fileprivate enum Kind {
    case standardInput
    case nullDevice
    case unmanaged(FileDescriptor)
  }
  fileprivate let kind: Kind
}

/**
 A value representing the output of a shell command
 */
public struct Output {

  /**
   An `Output` correpsonding to `stdout`
   */
  public static let standardOutput = Output(kind: .standardOutput)

  /**
   An `Output` correpsonding to `stderr`
   */
  public static let standardError = Output(kind: .standardError)

  /**
   An `Output` correpsonding to a null output device which drops any output it receives
   */
  public static let nullDevice = Output(kind: .nullDevice)

  /**
   A special `Output` which aborts if any input is read.
   */
  public static let fatalDevice = Output(kind: .fatalDevice)

  /**
   An output which records to a specified `Recording`
   */
  public static func record(to recording: Recorder.Recording) -> Output {
    Output(kind: .recording(recording))
  }

  /**
   A type which records the output of a shell command and can distinguish between standard output and standard error
   */
  public actor Recorder {

    public init() {}

    public func write<T: TextOutputStream>(to stream: inout T) async {
      for (_, buffer) in strings {
        buffer.write(to: &stream)
      }
    }

    /**
     A specialized value for recording output to a recorder
     */
    public struct Recording {
      public func write<T: TextOutputStream>(to stream: inout T) async {
        for (source, buffer) in await recorder.strings {
          if source == self.source {
            buffer.write(to: &stream)
          }
        }
      }

      fileprivate let recorder: Recorder
      fileprivate let source: Source
    }

    /**
     A `Recording` which records output to this recorder (simulating `stdout`)
     */
    public var output: Recording { Recording(recorder: self, source: .output) }

    /**
     A `Recording` which records errors to this recorder (siulating `stderr`)
     */
    public var error: Recording { Recording(recorder: self, source: .error) }

    /**
     Record data to the specific source
     */
    public func record(_ string: String, from source: Source) {
      strings.append((source, string))
    }

    /**
     Which source to record data to
     */
    public enum Source {
      case output, error
    }
    fileprivate var strings: [(Source, String)] = []
  }

  /**
   An output backed by an unmanaged file descriptor. It is the caller's responsibility to ensure that this file descriptor remains valid for as long as this input is in use.
   */
  public static func unmanaged(_ fileDescriptor: SystemPackage.FileDescriptor) -> Output {
    Output(kind: .unmanaged(fileDescriptor))
  }

  /**
   Creates a file decriptor representing this output which will be valid for the duration of `operation`
   - Parameters:
    - Context: The context to use to create the file descriptor
   */
  public func withFileDescriptor<T>(
    in context: Context,
    _ operation: (SystemPackage.FileDescriptor) async throws -> T
  ) async throws -> T {
    switch kind {
    case .standardOutput:
      return try await operation(.standardOutput)
    case .standardError:
      return try await operation(.standardError)
    case .nullDevice:
      return try await context.withNullOutputDevice(operation)
    case .fatalDevice:
      return try await context.withFatalOutputDevice(operation)
    case .recording(let recording):
      return try await Builtin.pipe(
        operation,
        to: { input in
          try await context.withNullOutputDevice { output in
            try await Builtin.withChannel(input: input, output: output, in: context) { channel in
              for try await buffer in channel.input.byteBuffers {
                await recording.recorder.record(String(buffer: buffer), from: recording.source)
              }
            }
          }
        }
      ).source
    case .unmanaged(let fileDescriptor):
      return try await operation(fileDescriptor)
    }
  }

  fileprivate enum Kind {
    case standardOutput
    case standardError
    case nullDevice
    case fatalDevice
    case unmanaged(FileDescriptor)
    case recording(Recorder.Recording)
  }
  fileprivate let kind: Kind
}
