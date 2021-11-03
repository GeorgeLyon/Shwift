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

  public struct Executable {
    
    public init(path: FilePath) {
      self.path = path
    }
    
    public let path: FilePath

  }
  
}