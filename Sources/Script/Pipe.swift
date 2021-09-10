
import Shell

@discardableResult
public func |<T> (
  source: @Sendable () async throws -> Void,
  destination: @Sendable () async throws -> T
) async throws -> T {
  try await Shell.current.pipe { shell in
    try await Shell.withSubshell(shell, operation: source)
  } to: { shell in
    try await Shell.withSubshell(shell, operation: destination)
  }
}


