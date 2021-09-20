
import Shell

public extension Script {
  
  func capture() -> Shell._Invocation<String> {
    Shell._Invocation { _ in
      try await collect().body().joined(separator: "\n")
    }
  }
  
  func map(transform: @escaping (String) async throws -> String) -> Shell._Invocation<Void> {
    compactMap(transform: transform)
  }
  
  func compactMap(transform: @escaping (String) async throws -> String?) -> Shell._Invocation<Void> {
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
  
  func collect() -> Shell._Invocation<[String]> {
    reduce(into: []) { $0.append($1) }
  }
  
  func reduce<T>(
    into initialResult: T,
    _ updateAccumulatingResult: @escaping (inout T, String) async throws -> Void
  ) -> Shell._Invocation<T> {
    Shell._Invocation { shell in
      try await shell.builtin { handle in
        try await handle.input.lines.reduce(into: initialResult, updateAccumulatingResult)
      }
    }
  }
  
  func reduce<T>(
    _ initialResult: T,
    _ nextPartialResult: @escaping (T, String) async throws -> T
  ) -> Shell._Invocation<T> {
    Shell._Invocation { shell in
      try await shell.builtin { handle in
        try await handle.input.lines.reduce(initialResult, nextPartialResult)
      }
    }
  }
  
}
