
extension Shell {
  
  public struct Input {
    
    public static let standardInput = Input(kind: .standardInput)
    
    /**
     An input roughly analogous to using the null device (`/dev/null`).
     */
    public static let nullDevice = Input(kind: .nullDevice)
    
    fileprivate enum Kind {
      case standardInput
      case nullDevice
    }
    fileprivate let kind: Kind
  }
  
  public struct Output {
    
    public static let standardOutput = Output(kind: .standardOutput)
    
    public static let standardError = Output(kind: .standardError)
    
    public static let nullDevice = Output(kind: .nullDevice)
    
    fileprivate enum Kind {
      case standardOutput
      case standardError
      case nullDevice
    }
    fileprivate let kind: Kind
  }
  
  func withFileDescriptor<T>(
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
    }
  }
  
  func withFileDescriptor<T>(
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
    }
  }
}
