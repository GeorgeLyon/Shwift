import SystemPackage

#if canImport(Glibc)
  import Glibc
#endif

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

  func closeAfter<T>(
    _ operation: () async throws -> T
  ) async throws -> T {
    do {
      let outcome = try await operation()
      try close()
      return outcome
    } catch {
      try! close()
      throw error
    }
  }

}
