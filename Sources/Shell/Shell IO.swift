
extension Shell {
  
  public struct Input {
    
    public static let standardInput = Input(kind: .standardInput)
    
    /**
     An input roughly analogous to using the null device (`/dev/null`).
     */
    public static let nullDevice = Input(kind: .nullDevice)
    
    func withFileDescriptor<T>(
      _ operation: (FileDescriptor) async throws -> T
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
      }
    }
    
    private enum Kind {
      case standardInput
      case nullDevice
    }
    private let kind: Kind
  }
  
  public struct Output {
    
    public static let standardOutput = Output(kind: .standardOutput)
    
    public static let standardError = Output(kind: .standardError)
    
    public static let nullDevice = Output(kind: .nullDevice)
    
    func withFileDescriptor<T>(
      _ operation: (FileDescriptor) async throws -> T
    ) async throws -> T {
      switch kind {
      case .standardOutput:
        return try await operation(.standardOutput)
      case .standardError:
        return try await operation(.standardError)
      case .nullDevice:
        let descriptor: FileDescriptor = try .open("/dev/null", .writeOnly)
        return try await descriptor.closeAfter {
          try await operation(descriptor)
        }
      }
    }
    
    private enum Kind {
      case standardOutput
      case standardError
      case nullDevice
    }
    private let kind: Kind
  }
  
}
