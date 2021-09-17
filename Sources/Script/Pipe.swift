
import Shell

@discardableResult
public func |<T> (
  source: Shell._Invocation<Void>,
  destination: Shell._Invocation<T>
) async throws -> T {
  try await Shell.current.pipe { shell in
    try await Shell.withSubshell(shell) { try await source.body() }
  } to: { shell in
    try await Shell.withSubshell(shell) { try await destination.body() }
  }
}

@discardableResult
@_disfavoredOverload
public func |<T> (
  source: Shell._Invocation<Void>,
  destination: Shell._Invocation<T>
) async throws -> Shell._Invocation<T> {
  Shell._Invocation {
    try await source | destination
  }
}

extension Shell {
  
  /**
   We use this type to work around https://bugs.swift.org/browse/SR-14517
   
   Instead of having `|` take async autoclosure arguments, we have it take this type, and provide disfavored overloads which create `_Invocation` for interesting APIs. Users should never interact with this type directly.
   */
  public struct _Invocation<T> {
    let body: () async throws -> T
  }
  
}
