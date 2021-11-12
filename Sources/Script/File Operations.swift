
import Shell
import SystemPackage
@_implementationOnly import Foundation

// MARK: - Operators

public func > (source: Shell._Invocation<Void>, path: FilePath) async throws {
  try await source | Shell._Invocation { shell in
    try await shell.write(to: path)
  }
}

@_disfavoredOverload
public func > (source: Shell._Invocation<Void>, path: FilePath) -> Shell._Invocation<Void> {
  Shell._Invocation {
    try await source > path
  }
}

public func >> (source: Shell._Invocation<Void>, path: FilePath) async throws {
  try await source | Shell._Invocation { shell in
    try await shell.write(to: path, append: true)
  }
}

@_disfavoredOverload
public func >> (source: Shell._Invocation<Void>, path: FilePath) -> Shell._Invocation<Void> {
  Shell._Invocation {
    try await source >> path
  }
}

public func < <T>(destination: Shell._Invocation<T>, path: FilePath) async throws -> T {
  try await Shell._Invocation { shell in
    try await shell.read(from: path)
  } | destination
}

@_disfavoredOverload
public func < <T>(destination: Shell._Invocation<T>, path: FilePath) -> Shell._Invocation<T> {
  Shell._Invocation {
    try await destination < path
  }
}

// MARK: - Functions

public func contents(of path: FilePath) async throws -> String {
  try await outputOf {
    try await Shell.withCurrent { shell in
      try await shell.read(from: path)
    }
  }
}

public func write(
  _ value: String,
  to path: FilePath
) async throws {
  try await echo(value) > path
}

public func item(at path: FilePath) async throws -> Shell.Item {
  try await Shell.withCurrent { shell in
    Shell.Item(path: shell.workingDirectory.pushing(path))
  }
}

extension Shell {
  
  /**
   An item on the file system which may or may not exist
   */
  public struct Item {
    
    public var exists: Bool {
      FileManager.default.fileExists(atPath: path.string)
    }
    
    public enum Kind {
      case file
      case directory
    }
    public var kind: Kind? {
      var isDirectory: ObjCBool = false
      if FileManager.default.fileExists(atPath: path.string, isDirectory: &isDirectory) {
        if isDirectory.boolValue {
          return .directory
        } else {
          return .file
        }
      } else {
        return nil
      }
    }
    
    public func delete() throws {
      try FileManager.default.removeItem(atPath: path.string)
    }
    
    public func deleteIfExists() throws {
      if exists {
        try FileManager.default.removeItem(atPath: path.string)
      }
    }
    
    fileprivate let path: FilePath
  }
  
}
