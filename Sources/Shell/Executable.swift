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
    
    public let path: FilePath

    public struct NotFound: Error {
      public let name: String
    }
    
    fileprivate init(path: FilePath) {
      self.path = path
    }
  }
  
  /**
   - returns: An executable if one is present in the environment search paths, otherwise throws an executable not found error.
   */
  public func executable(named name: String) throws -> Executable {
    guard let executable = try executable(named: name, required: false) else {
      throw Executable.NotFound(name: name)
    }
    return executable
  }

  /**
   - returns: An executable if one is present in the environment search paths.
   - Parameters:
    - required: Should only ever be set to `false`
   */
  public func executable(named name: String, required: Bool) throws -> Executable? {
    precondition(!required)
    guard let path = try path(forExecutableNamed: name, strict: false) else {
      return nil
    }
    return Executable(path: path)
  }
  
}
