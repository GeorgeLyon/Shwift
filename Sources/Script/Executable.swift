
import Shell

// MARK: - Invoking Executables by Name

public extension Script {
  
  func execute(_ executableName: String, _ arguments: String?...) async throws {
    try await execute(executableName, arguments: arguments)
  }
  
  func execute(_ executableName: String, arguments: [String?]) async throws {
    try await Shell.withCurrent { shell in
      try await shell.execute(
        executable(named: executableName),
        withArguments: arguments)
    }
  }
  
  @_disfavoredOverload
  func execute(
    _ executableName: String,
    _ arguments: String?...
  ) async throws -> Shell._Invocation<Void> {
    try await execute(executableName, arguments: arguments)
  }
  
  @_disfavoredOverload
  func execute(
    _ executableName: String,
    arguments: [String?]
  ) async throws -> Shell._Invocation<Void> {
    Shell._Invocation { shell in
      try await execute(executableName, arguments: arguments)
    }
  }
  
}

// MARK: - Resolving Executables

public extension Script {
  func executable(named name: String) async throws -> Shell.Executable {
    return try await Shell.withCurrent { shell in
      try shell.executable(named: name)
    }
  }
  
  /**
   - Parameters:
     - required: Should only ever be set to `false`, implying the initializer returns `nil` if the specified executable is not found.
   */
  func executable(named name: String, required: Bool) async throws -> Shell.Executable? {
    return try await Shell.withCurrent { shell in
      try shell.executable(named: name, required: required)
    }
  }
}

// MARK: - Invoking Executables

public extension Shell.Executable {
  
  func callAsFunction(_ arguments: String?...) async throws {
    try await callAsFunction(arguments: arguments)
  }
  
  func callAsFunction(arguments: [String?]) async throws {
    try await Shell.withCurrent { shell in
      try await shell.execute(self, withArguments: arguments)
    }
  }
  
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
  
}

// MARK: - Support

private extension Shell {
  /**
   - note: In shell scripts, specifying an environment variable which is not defined as an argument effectively skips that argument. For instance `echo Foo $NOT_DEFINED Bar` would be analogous to `echo Foo  Bar`. We mirror this behavior in Script by allowing arguments to be `nil`.
   */
  func execute(_ executable: Executable, withArguments arguments: [String?]) async throws {
    try await self.execute(executable, withArguments: arguments.compactMap { $0 })
  }
}
