
import Shell

public extension Script {
  func executable(named name: String) throws -> Shell.Executable {
    guard let executable = try executable(named: name, required: false) else {
      throw Shell.Executable.Error.executableNotFound(name)
    }
    return executable
  }
  
  /**
   - Parameters:
     - required: Should only ever be set to `false`, implying the initializer returns `nil` if the specified executable is not found.
   */
  func executable(named name: String, required: Bool) throws -> Shell.Executable? {
    return try Shell.current.executable(named: name)
  }
}

public extension Shell.Executable {
  func callAsFunction(_ arguments: String?...) async throws {
    try await callAsFunction(arguments: arguments)
  }
  func callAsFunction(arguments: [String?]) async throws {
    try await Shell.current.execute(self, arguments: arguments)
  }
}
