import SystemPackage

#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
import Darwin

#elseif os(Linux) || os(FreeBSD) || os(Android)
import Glibc
#elseif os(Windows)
import ucrt
#else
#error("Unsupported Platform")
#endif

extension FileDescriptor {
  typealias Pipe = (input: FileDescriptor, output: FileDescriptor)
  
  static func openPipe() throws -> Pipe {
    var fds: (Int32, Int32) = (-1, -1)
    withUnsafeMutableBytes(of: &fds) { bytes in
      let fds = bytes.bindMemory(to: Int32.self)
      let result = pipe(fds.baseAddress!)
      precondition(result == 0)
    }
    return (FileDescriptor(rawValue: fds.0), FileDescriptor(rawValue: fds.1))
  }
  
  func closeAfter<T>(_ operation: () async throws -> T) async throws -> T {
    let result: T
    do {
      result = try await operation()
    } catch {
      do {
        try close()
      } catch {
        print(error)
        assertionFailure()
      }
      throw error
    }
    try close()
    return result
  }
}
