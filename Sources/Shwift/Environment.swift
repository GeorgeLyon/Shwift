import SystemPackage

@_implementationOnly import Foundation

public struct Environment: ExpressibleByDictionaryLiteral {
  public init() {
    entries = []
  }

  public init(dictionaryLiteral elements: (String, String)...) {
    entries = elements.map { Entry(string: "\($0.0)=\($0.1)") }
  }
  
  public static var process: Environment {
    var environment = Environment()
    var entry = environ
    while let cString = entry.pointee {
      defer { entry = entry.advanced(by: 1) }
      environment.entries.append(Entry(string: String(cString: cString)))
    }
    return environment
  }

  public subscript(name: String) -> String? {
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
  
  public mutating func unset(_ name: String) {
    if let index = entries.firstIndex(where: { $0.components.name == name }) {
      entries.remove(at: index)
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

  public struct SearchResults {
    
    public enum Event {
      case encountered(Error)
      case pathIsNotAbsolute
      case candidateIsNotExecuable
      case found
    }
    public fileprivate(set) var log: [(path: FilePath, event: Event)] = []
    
    public var matches: [FilePath] {
      log.compactMap { entry in
        if case .found = entry.event {
          return entry.path
        } else {
          return nil
        }
      }
    }
    
    fileprivate init() { }
  }
  
  public var searchPaths: [FilePath] {
    self["PATH"]?
      .components(separatedBy: ":")
      .map(FilePath.init(_:)) ?? []
  }
  
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
        candidates = try fileManager
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

}
