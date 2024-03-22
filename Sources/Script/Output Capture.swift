import Shwift

public func outputOf(_ operation: @escaping () async throws -> Void) async throws -> String {
  let lines = try await Shell.PipableCommand(operation) | reduce(into: []) { $0.append($1) }
  return lines.joined(separator: "\n")
}

public func splitInput<T>(
  on separator: Character = "\n",
  into initialResult: T,
  _ updateAccumulatingResult: @escaping (inout T, String) async throws -> Void
) -> Shell.PipableCommand<T> {
  Shell.PipableCommand {
    try await Shell.invoke { _, invocation in
      try await invocation.builtin { channel in
        try await channel.input.segmented(by: separator)
          .reduce(into: initialResult, updateAccumulatingResult)
      }
    }
  }
}
