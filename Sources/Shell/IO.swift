import Foundation
import SystemPackage


extension Shell {

  public struct Input: Sendable {

    public static let standardInput = Input(kind: .unmanaged(.standardInput))

    /**
     Reads from the null device (`/dev/null`)

     - note: While this could feasibly be implemented using `fileDescriptor`, we prefer to special case it so that the attempt to create the file descriptor (which can fail) can be deferred and simply creating a new shell does not need to be fallible.
     */
    public static let nullDevice = Input(kind: .nullDevice)

    init(_ fileDescriptor: FileDescriptor){
      self.kind = .unmanaged(fileDescriptor)
    }

    private init(kind: Kind) {
      self.kind = kind
    }
    
    fileprivate enum Kind {
      case unmanaged(FileDescriptor)
      case nullDevice
    }
    fileprivate let kind: Kind
  }

  public struct Output: Sendable {

    public static let standardOutput = Output(kind: .unmanaged(.standardOutput))

    public static let standardError = Output(kind: .unmanaged(.standardError))

    /**
     Forwards output to the null device (`/dev/null`)

     - note: While this could feasibly be implemented using `fileDescriptor`, we prefer to special case it so that the attempt to create the file descriptor (which can fail) can be deferred and simply creating a new shell does not need to be fallible.
     */
    public static let nullDevice = Output(kind: .nullDevice)

    init(_ fileDescriptor: FileDescriptor){
      self.kind = .unmanaged(fileDescriptor)
    }

    private init(kind: Kind) {
      self.kind = kind
    }
    
    fileprivate enum Kind {
      case unmanaged(FileDescriptor)
      case nullDevice
    }
    fileprivate let kind: Kind
  }
}

extension Shell {
  func withFileDescriptor<T>(
    for input: Input,
    operation: (FileDescriptor) async throws -> T
  ) async throws -> T {
    switch input.kind {
    case .unmanaged(let fileDescriptor):
      return try await operation(fileDescriptor)
    case .nullDevice:
      return try await withNullDevice(.readOnly, operation: operation)
    }
  }
  
  func withFileDescriptor<T>(
    for output: Output,
    operation: (FileDescriptor) async throws -> T
  ) async throws -> T {
    switch output.kind {
    case .unmanaged(let fileDescriptor):
      return try await operation(fileDescriptor)
    case .nullDevice:
      return try await withNullDevice(.writeOnly, operation: operation)
    }
  }
  
  private func withNullDevice<T>(
    _ accessMode: FileDescriptor.AccessMode,
    operation: (FileDescriptor) async throws -> T
  ) async throws -> T {
    let fileDescriptor =
      try FileDescriptor
      .open(nullDevicePath, accessMode)
    do {
      let result = try await operation(fileDescriptor)
      do {
        try fileDescriptor.close()
      } catch {
        print(error)
        assertionFailure()
      }
      return result
    } catch {
      close(fileDescriptor)
      throw error
    }
  }
  
  private func close(_ fileDescriptor: FileDescriptor) {
    do {
      try fileDescriptor.close()
    } catch let error {
      /// Eventually we may want to report these errors to the shell
      assertionFailure()
      /// We need to give the error an explicit name as LLDB gets confused when referencing it using the implicit name
      _ = error
    }
  }
  
}

private let nullDevicePath = "/dev/null"
