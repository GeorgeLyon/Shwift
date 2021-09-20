
import Shell
import Foundation

public extension Script {
  
  func read(from filePath: FilePath) -> Shell._Invocation<Void> {
    Shell._Invocation { shell in
      try await shell.read(from: filePath)
    }
  }
  
  func write(to filePath: FilePath) -> Shell._Invocation<Void> {
    Shell._Invocation { shell in
      try await shell.write(to: filePath)
    }
  }
  
  func item(at path: FilePath) async -> Shell.Item {
    await Shell.withCurrent { shell in
      Shell.Item(path: shell.directory.pushing(path))
    }
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
    
    fileprivate let path: FilePath
  }
  
}
