
import Shell

// MARK: - Echo

/**
 Prints a set of items to the specified shell output
 
 The API is meant to mirror `Swift.print`.
 */
public func echo(
  _ items: Any...,
  separator: String = " ",
  terminator: String = "\n",
  to outputChannel: Shell.OutputChannel = .output
) async throws {
  try await Shell.withCurrent { shell in
    try await shell.echo(items: items, separator: separator, terminator: terminator, to: outputChannel)
  }
}

/**
 Prints a set of items to the specified shell output
 
 The API is meant to mirror `Swift.print`.
 */
@_disfavoredOverload
public func echo(
  _ items: Any...,
  separator: String = " ",
  terminator: String = "\n",
  to outputChannel: Shell.OutputChannel = .output
) -> Shell._Invocation<Void> {
  Shell._Invocation { shell in
    try await shell.echo(items: items, separator: separator, terminator: terminator, to: outputChannel)
  }
}

extension Shell {
  fileprivate func echo(
    items: [Any],
    separator: String = " ",
    terminator: String = "\n",
    to outputChannel: Shell.OutputChannel = .output
  ) async throws {
    try await builtin { handle in
      let target: Builtin.Output
      switch outputChannel {
      case .output:
        target = handle.output
      case .error:
        target = handle.error
      }
      try await target.withTextOutputStream { stream in
        items
          .flatMap { [String(describing: $0), separator] }
          .dropLast()
          .forEach { stream.write($0) }
        stream.write(terminator)
      }
    }
  }
}

public func builtin<T>(
  _ operation: @escaping (inout Builtin.Handle) async throws -> T
) async throws -> T{
  try await Shell.withCurrent { shell in
    try await shell.builtin(operation: operation)
  }
}

@_disfavoredOverload
public func builtin<T>(
  _ operation: @escaping (inout Builtin.Handle) async throws -> T
) -> Shell._Invocation<T> {
  Shell._Invocation {
    try await builtin(operation)
  }
}
