import Foundation
import SystemPackage

extension Shell {
  public struct Environment: ExpressibleByDictionaryLiteral, Sendable {
    public static let process = Environment(values: ProcessInfo.processInfo.environment)
    public init(dictionaryLiteral elements: (String, String?)...) {
      self.init(values: Dictionary(uniqueKeysWithValues: elements))
    }
    public init(values: [String: String?]) {
      self.values = values.compactMapValues { $0 }
    }
    public mutating func set(_ newValues: KeyValuePairs<String, String?>) {
      for (key, value) in newValues {
        if let value = value {
          self.values[key] = value
        } else {
          self.values.removeValue(forKey: key)
        }
      }
    }
    public private(set) var values: [String: String]
  }
}

// MARK: - PATH

extension Shell.Environment {

  func path(
    forExecutableNamed name: String,
    strict: Bool = true
  ) throws -> FilePath? {
    guard
      let searchPaths = values["PATH"]?
        .components(separatedBy: ":")
    else {
      return nil
    }

    enum Error: Swift.Error {
      case directoryDoesNotExist(String)
      case expectedDirectoryFoundFile(String)
      case rejectingRelativePath(String)
    }
    let fileManager: FileManager = .default
    return
      try searchPaths
      .lazy
      .filter { path in
        do {
          var isDirectory: ObjCBool = false
          let exists = fileManager.fileExists(
            atPath: path,
            isDirectory: &isDirectory)
          guard exists else {
            throw Error.directoryDoesNotExist(path)
          }
          guard isDirectory.boolValue else {
            throw Error.expectedDirectoryFoundFile(path)
          }
          return true
        } catch  where !strict {
          return false
        }
      }
      .filter { path in
        do {
          guard FilePath(path).isAbsolute else {
            throw Error.rejectingRelativePath(path)
          }
          return true
        } catch  where !strict {
          return false
        }
      }
      .compactMap { path -> URL? in
        do {
          return
            try fileManager
            .contentsOfDirectory(
              at: URL(fileURLWithPath: path),
              includingPropertiesForKeys: [.isExecutableKey],
              options: .skipsSubdirectoryDescendants
            )
            .lazy
            .filter { $0.lastPathComponent == name }
            .filter { url in
              do {
                return try url.resourceValues(forKeys: [.isExecutableKey]).isExecutable ?? false
              } catch  where !strict {
                return false
              }
            }
            .first
        } catch  where !strict {
          return nil
        }
      }
      .first
      .map(\.path)
      .map(FilePath.init(_:))
  }

}
