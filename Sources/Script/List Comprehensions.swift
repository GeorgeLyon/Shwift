
import Shell

/**
 By default, shell output is processed as a list of lines
 */

public func map(transform: @escaping (String) async throws -> String) -> Shell._Invocation<Void> {
  compactMap(transform: transform)
}

public func compactMap(transform: @escaping (String) async throws -> String?) -> Shell._Invocation<Void> {
  Shell._Invocation { shell in
    try await shell.builtin { handle in
      for try await line in handle.input.lines.compactMap(transform) {
        try await handle.output.withTextOutputStream { stream in
          print(line, to: &stream)
        }
      }
    }
  }
}

public func reduce<T>(
  into initialResult: T,
  _ updateAccumulatingResult: @escaping (inout T, String) async throws -> Void
) -> Shell._Invocation<T> {
  Shell._Invocation { shell in
    try await shell.builtin { handle in
      try await handle.input.lines.reduce(into: initialResult, updateAccumulatingResult)
    }
  }
}

public func reduce<T>(
  _ initialResult: T,
  _ nextPartialResult: @escaping (T, String) async throws -> T
) -> Shell._Invocation<T> {
  Shell._Invocation { shell in
    try await shell.builtin { handle in
      try await handle.input.lines.reduce(initialResult, nextPartialResult)
    }
  }
}
