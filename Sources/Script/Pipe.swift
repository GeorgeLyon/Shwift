
import Shell

@discardableResult
public func |<T> (
  source: @Sendable @autoclosure () async throws -> Void,
  destination: @Sendable @autoclosure () async throws -> T
) async throws -> T {
  try await Shell.current.pipe { shell in
    try await Shell.withSubshell(shell, operation: source)
  } to: { shell in
    try await Shell.withSubshell(shell, operation: destination)
  }
}


