import SystemPackage

@_implementationOnly import Foundation

/**
 A type representing the enviornment variables associated with a shell command
 */
public struct Environment: ExpressibleByDictionaryLiteral {

  /**
   Create an empty environment.
   */
  public init() {
    entries = []
  }

  public init(dictionaryLiteral elements: (String, String)...) {
    entries = elements.map { Entry(string: "\($0.0)=\($0.1)") }
  }

  /**
   The environment associated with the current process at this moment in time. Modification to the process environment will not be reflected in this value once it is created.
   */
  public static var process: Environment {
    var environment = Environment()
    var entry = environ
    while let cString = entry.pointee {
      defer { entry = entry.advanced(by: 1) }
      environment.entries.append(Entry(string: String(cString: cString)))
    }
    return environment
  }

  /**
   Update a variable in the environment.
   - Parameters:
    - name: The name of the variable to be updated
    - value: The new string value of the variable, or `nil` indicating that the entry for this variable should be removed
   */
  public mutating func setValue(_ value: String?, forVariableNamed name: String) {
    self[name] = value
  }

  subscript(name: String) -> String? {
    get {
      for entry in entries {
        let components = entry.components
        if components.name == name {
          return String(components.value)
        }
      }
      return nil
    }
    set {
      let index = entries.firstIndex(where: { $0.components.name == name })
      if let newValue = newValue {
        let entry = Entry(string: "\(name)=\(newValue)")
        if let index = index {
          entries[index] = entry
        } else {
          entries.append(entry)
        }
      } else if let index = index {
        entries.remove(at: index)
      }
    }
  }

  var strings: [String] { entries.map(\.string) }

  private init(entries: [Entry]) {
    self.entries = entries
  }
  private struct Entry {
    var components: (name: Substring, value: Substring) {
      let index = string.firstIndex(of: "=") ?? string.endIndex
      let name = string[string.startIndex..<index]
      let value = string[string.index(after: index)...]
      return (name: name, value: value)
    }

    let string: String
  }
  private var entries: [Entry]
}

// MARK: - PATH

extension Environment {

  /**
   The result of searching for an executable in this environment. The results are expressed as an array of events corresponding to the specific interpretation of the `PATH` variable during the search.
   */
  public struct SearchResults {

    public enum Event {

      /**
       An error was encountered when reading from the filesystem
       */
      case encountered(Error)

      /**
       A path in the `PATH` variable is not absolute, and as a result will not be searched
       */
      case pathIsNotAbsolute

      /**
       A file was found with the specified name, but that file is not executable
       */
      case candidateIsNotExecuable

      /**
       An executable was found with the specified name
       */
      case found
    }

    /**
     The complete list of events, along with the file path they are associated with
     */
    public fileprivate(set) var log: [(path: FilePath, event: Event)] = []

    /**
     Executables that were found, returned in the same order as their containing directory occured in the `PATH` variable
     */
    public var matches: [FilePath] {
      log.compactMap { entry in
        if case .found = entry.event {
          return entry.path
        } else {
          return nil
        }
      }
    }

    fileprivate init() {}
  }

  /**
   Searches for an executable with the specified `name` in the `PATH` associated with this environment.
   */
  public func searchForExecutables(named name: String) -> SearchResults {
    let fileManager = FileManager.default
    var results = SearchResults()
    for searchPath in searchPaths {
      guard searchPath.isAbsolute else {
        results.log.append((searchPath, .pathIsNotAbsolute))
        continue
      }

      let candidates: [URL]
      do {
        candidates =
          try fileManager
          .contentsOfDirectory(
            at: URL(fileURLWithPath: searchPath.string),
            includingPropertiesForKeys: [.isExecutableKey],
            options: .skipsSubdirectoryDescendants)
      } catch {
        results.log.append((searchPath, .encountered(error)))
        continue
      }

      for candidate in candidates {
        let filePath = FilePath(candidate.path)
        do {
          guard candidate.lastPathComponent == name else {
            continue
          }
          guard try candidate.resourceValues(forKeys: [.isExecutableKey]).isExecutable! else {
            results.log.append((filePath, .candidateIsNotExecuable))
            continue
          }
          results.log.append((filePath, .found))
        } catch {
          results.log.append((filePath, .encountered(error)))
        }
      }
    }
    return results
  }

  var searchPaths: [FilePath] {
    self["PATH"]?
      .components(separatedBy: ":")
      .map(FilePath.init(_:)) ?? []
  }

}
