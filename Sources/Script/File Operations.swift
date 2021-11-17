
import Shwift
import SystemPackage
@_implementationOnly import Foundation

// MARK: - Operators

public func > (source: Shell.PipableCommand<Void>, path: FilePath) async throws {
  try await source | Shell.PipableCommand {
    try await Shell.invoke { shell, invocation in
      let absolutePath = shell.workingDirectory.pushing(path)
      try await Builtin.write(
        invocation.standardInput,
        to: absolutePath,
        in: invocation.context)
    }
  }
}

@_disfavoredOverload
public func > (source: Shell.PipableCommand<Void>, path: FilePath) -> Shell.PipableCommand<Void> {
  Shell.PipableCommand {
    try await source > path
  }
}

public func >> (source: Shell.PipableCommand<Void>, path: FilePath) async throws {
  try await source | Shell.PipableCommand {
    try await Shell.invoke { shell, invocation in
      let absolutePath = shell.workingDirectory.pushing(path)
      try await Builtin.write(
        invocation.standardInput,
        to: absolutePath,
        append: true,
        in: invocation.context)
    }
  }
}

@_disfavoredOverload
public func >> (source: Shell.PipableCommand<Void>, path: FilePath) -> Shell.PipableCommand<Void> {
  Shell.PipableCommand {
    try await source >> path
  }
}

public func < <T>(destination: Shell.PipableCommand<T>, path: FilePath) async throws -> T {
  try await Shell.PipableCommand {
    try await Shell.invoke { shell, invocation in
      let absolutePath = shell.workingDirectory.pushing(path)
      return try await Builtin.read(
        from: absolutePath,
        to: invocation.standardOutput,
        in: invocation.context)
    }
  } | destination
}

@_disfavoredOverload
public func < <T>(destination: Shell.PipableCommand<T>, path: FilePath) -> Shell.PipableCommand<T> {
  Shell.PipableCommand {
    try await destination < path
  }
}

// MARK: - Functions

public func contents(of path: FilePath) async throws -> String {
  try await outputOf {
    try await Shell.invoke { shell, invocation in
      let absolutePath = shell.workingDirectory.pushing(path)
      return try await Builtin.read(
        from: absolutePath,
        to: invocation.standardOutput,
        in: invocation.context)
    }
  }
}

public func write(
  _ value: String,
  to path: FilePath
) async throws {
  try await echo(value) > path
}

public func item(at path: FilePath) -> Shell.Item {
  Shell.Item(path: Shell.current.workingDirectory.pushing(path))
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
