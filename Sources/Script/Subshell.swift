
public func subshell<T>(
  pushing path: FilePath? = nil,
  updatingEnvironmentWith environmentUpdates: [String: String?] = [:],
  standardInput: Shell.Input? = nil,
  standardOutput: Shell.Output? = nil,
  standardError: Shell.Output? = nil,
  operation: @escaping () async throws -> T
) async throws -> T {
  try await Shell.withCurrent { shell in
    var environment = shell.environment
    for (key, value) in environmentUpdates {
      environment[key] = value
    }
    let subshell = shell.subshell(
      pushing: path,
      replacingEnvironmentWith: environment,
      standardInput: standardInput,
      standardOutput: standardOutput,
      standardError: standardError)
    return try await Shell.withSubshell(subshell, operation: operation)
  }
}

@_disfavoredOverload
public func subshell<T>(
  pushing path: FilePath? = nil,
  updatingEnvironmentWith environmentUpdates: [String: String?] = [:],
  standardInput: Shell.Input? = nil,
  standardOutput: Shell.Output? = nil,
  standardError: Shell.Output? = nil,
  operation: @escaping () async throws -> T
) -> Shell._Invocation<T> {
  Shell._Invocation {
    try await subshell(
      pushing: path,
      updatingEnvironmentWith: environmentUpdates,
      standardInput: standardInput,
      standardOutput: standardOutput,
      standardError: standardError,
      operation: operation)
  }
}
