import Shwift

@discardableResult
public func | <T>(
  source: Shell.PipableCommand<Void>,
  destination: Shell.PipableCommand<T>
) async throws -> T {
  try await pipe(
    .output,
    of: {
      try? await source.body()
    },
    to: destination.body
  ).destination
}

@discardableResult
@_disfavoredOverload
public func | <T>(
  source: Shell.PipableCommand<Void>,
  destination: Shell.PipableCommand<T>
) async throws -> Shell.PipableCommand<T> {
  Shell.PipableCommand {
    try await source | destination
  }
}

/**
 Special form of `pipe` which allows piping to a builtin like `map`
 */
public func pipe<SourceOutcome, DestinationOutcome>(
  _ outputChannel: Shell.OutputChannel,
  of source: () async throws -> SourceOutcome,
  to destination: Shell.PipableCommand<DestinationOutcome>
) async throws -> (source: SourceOutcome, destination: DestinationOutcome) {
  try await pipe(outputChannel, of: source, to: { try await destination.body() })
}

public func pipe<SourceOutcome, DestinationOutcome>(
  _ outputChannel: Shell.OutputChannel,
  of source: () async throws -> SourceOutcome,
  to destination: () async throws -> DestinationOutcome
) async throws -> (source: SourceOutcome, destination: DestinationOutcome) {
  try await Shell.invoke { shell, invocation in
    try await Builtin.pipe(
      { output in
        switch outputChannel {
        case .output:
          return try await subshell(
            standardOutput: .unmanaged(output),
            operation: source)
        case .error:
          return try await subshell(
            standardError: .unmanaged(output),
            operation: source)
        }
      },
      to: { input in
        try await subshell(
          standardInput: .unmanaged(input),
          operation: destination)
      })
  }
}

extension Shell {

  public enum OutputChannel {
    case output, error
  }

  /**
   We use this type to work around https://bugs.swift.org/browse/SR-14517

   Instead of having `|` take async autoclosure arguments, we have it take this type, and provide disfavored overloads which create `PipableCommand<T>` for interesting APIs. Some API doesn't really make sense outside of a pipe expression, and we only provide the `PipableCommand` variant for such API.
   */
  public struct PipableCommand<T> {
    init(_ body: @escaping () async throws -> T) {
      self.body = body
    }
    let body: () async throws -> T
  }

}
