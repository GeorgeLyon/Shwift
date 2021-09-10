import Foundation
import SystemPackage


extension Shell {

  public struct Input {

    public static let standardInput = Input(kind: .unmanaged(.standardInput))

    /**
     Reads from the null device (`/dev/null`)

     - note: While this could feasibly be implemented using `fileDescriptor`, we prefer to special case it so that the attempt to create the file descriptor (which can fail) can be deferred and simply creating a new shell does not need to be fallible.
     */
    public static let nullDevice = Input(kind: .nullDevice)

    static func unmanaged(_ fileDescriptor: CInt) -> Self {
      Input(kind: .unmanaged(FileDescriptor(rawValue: fileDescriptor)))
    }

    func withFileDescriptor<T>(_ body: (FileDescriptor) throws -> T) throws -> T {
      switch kind {
      case .unmanaged(let value):
        return try body(value)
      case .nullDevice:
        let fileDescriptor =
          try FileDescriptor
          .open(nullDevicePath, .readOnly)
        return try fileDescriptor.closeAfter { try body(fileDescriptor) }
      }
    }

    private enum Kind {
      case unmanaged(FileDescriptor)
      case nullDevice
    }
    private let kind: Kind
  }

  public struct Output {

    public static let standardOutput = Output(kind: .unmanaged(.standardOutput))

    public static let standardError = Output(kind: .unmanaged(.standardError))

    /**
     Forwards output to the null device (`/dev/null`)

     - note: While this could feasibly be implemented using `fileDescriptor`, we prefer to special case it so that the attempt to create the file descriptor (which can fail) can be deferred and simply creating a new shell does not need to be fallible.
     */
    public static let nullDevice = Output(kind: .nullDevice)

    static func unmanaged(_ fileDescriptor: CInt) -> Self {
      Output(kind: .unmanaged(FileDescriptor(rawValue: fileDescriptor)))
    }

    func withFileDescriptor<T>(_ body: (FileDescriptor) throws -> T) throws -> T {
      switch kind {
      case .unmanaged(let value):
        return try body(value)
      case .nullDevice:
        let fileDescriptor =
          try FileDescriptor
          .open(nullDevicePath, .writeOnly)
        return try fileDescriptor.closeAfter { try body(fileDescriptor) }
      }
    }
    
    private struct PipeError: Error { }

    private enum Kind {
      case unmanaged(FileDescriptor)
      case nullDevice
    }
    private let kind: Kind
  }
}

private let nullDevicePath = "/dev/null"
