#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#else
#error("Unsupported Platform")
#endif

import SystemPackage
@_implementationOnly import NIO

public typealias Executable = Shell.Executable

extension Shell {
  
  public func execute(_ executable: Executable, arguments: [String]) async throws {
    try await invoke { shell in
      try await Process.run(
        executablePath: executable.path,
        arguments: arguments,
        in: shell)
    }
  }
  
  public struct Executable {
    
    public init(path: FilePath) {
      self.path = path
    }
    
    public let path: FilePath

  }
  
}