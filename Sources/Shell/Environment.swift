import SystemPackage

@_implementationOnly import Foundation

extension Shell {

  func path(
    forExecutableNamed name: String,
    strict: Bool = true
  ) throws -> FilePath? {
    guard
      let searchPaths = environment["PATH"]?
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
