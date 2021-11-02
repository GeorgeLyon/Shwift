
import SystemPackage

#if canImport(Glibc)
import Glibc
#endif

/// Disambiguate between `NIO` and `SystemPackage`
typealias FileDescriptor = SystemPackage.FileDescriptor

extension FileDescriptor {
  
  static func withPipe<T>(
    _ operation: ((readEnd: FileDescriptor, writeEnd: FileDescriptor)) async throws -> T
  ) async throws -> T {
    let pipe = try Self.pipe()
    return try await pipe.writeEnd.closeAfter {
      try await pipe.readEnd.closeAfter {
        try await operation((readEnd: pipe.readEnd, writeEnd: pipe.writeEnd))
      }
    }
  }
  
  #if canImport(Glibc)
  /**
   - returns: An array of currently open file descriptors
   - warning: This method is not thread safe and might block. Also, this method uses heuris
   */
  static var openFileDescriptors: [FileDescriptor] {
    get throws {
      let directoryFileDescriptor = try Self.open("/proc/self/fd", .readOnly, options: .directory)
      let directory = fdopendir(directoryFileDescriptor.rawValue)!
      defer { 
        let returnValue = closedir(directory)
        precondition(returnValue == 0)
      }
      var openFileDescriptors: [FileDescriptor] = []
      while true {
        let name: String
        do {
          errno = 0
          guard let entry = readdir(directory) else {
            break
          }
          precondition(errno == 0)

          name = withUnsafeBytes(of: entry.pointee.d_name) { cName in
            return String(
              decoding: cName.prefix(while: { $0 != 0 }), 
              as: Unicode.UTF8.self)
          }
        }

        guard !name.allSatisfy({ $0 == "." }) else {
          continue
        }

        guard let fileDescriptor = CInt(name).map(FileDescriptor.init) else {
          fatalError()
        }
        guard fileDescriptor != directoryFileDescriptor else {
          continue
        }
        openFileDescriptors.append(fileDescriptor)
      }
      return openFileDescriptors
    }
  }
  #endif
  
  func closeAfter<T>(
    _ operation: () async throws -> T
  ) async throws -> T {
    do {
      let outcome =  try await operation()
      try close()
      return outcome
    } catch {
      try! close()
      throw error
    }
  }
  
}
