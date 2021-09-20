
import Shell

public extension Script {
  func executable(named name: String) async throws -> Shell.Executable {
    guard let executable = try await executable(named: name, required: false) else {
      throw Shell.Executable.Error.executableNotFound(name)
    }
    return executable
  }
  
  /**
   - Parameters:
     - required: Should only ever be set to `false`, implying the initializer returns `nil` if the specified executable is not found.
   */
  func executable(named name: String, required: Bool) async throws -> Shell.Executable? {
    precondition(required == false)
    return try await Shell.withCurrent { shell in
      try shell.executable(named: name)
    }
  }
}

public extension Shell.Executable {
  @_disfavoredOverload
  func callAsFunction(_ arguments: String?...) async throws -> Shell._Invocation<Void> {
    Shell._Invocation { _ in
      try await callAsFunction(arguments: arguments)
    }
  }
  @_disfavoredOverload
  func callAsFunction(arguments: [String?]) async throws -> Shell._Invocation<Void> {
    Shell._Invocation { _ in
      try await callAsFunction(arguments: arguments)
    }
  }
  func callAsFunction(_ arguments: String?...) async throws {
    try await callAsFunction(arguments: arguments)
  }
  func callAsFunction(arguments: [String?]) async throws {
    try await Shell.withCurrent { shell in
      try await shell.execute(self, arguments: arguments)
    }
  }
}
