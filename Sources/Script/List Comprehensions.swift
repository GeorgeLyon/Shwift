import Shwift

/**
 By default, shell output is processed as a list of lines
 */

public func map(transform: @Sendable @escaping (String) async throws -> String)
  -> Shell.PipableCommand<Void>
{
  compactMap(transform: transform)
}

public func compactMap(
  segmentingInputAt delimiter: Character = "\n",
  withOutputTerminator terminator: String = "\n",
  transform: @Sendable @escaping (String) async throws -> String?
) -> Shell.PipableCommand<Void> {
  Shell.PipableCommand {
    try await Shell.invoke { shell, invocation in
      try await invocation.builtin { channel in
        for try await line in channel.input.segmented(by: delimiter).compactMap(transform) {
          try await channel.output.withTextOutputStream { stream in
            print(line, terminator: terminator, to: &stream)
          }
        }
      }
    }
  }
}

public func reduce<T>(
  into initialResult: T,
  _ updateAccumulatingResult: @escaping (inout T, String) async throws -> Void
) -> Shell.PipableCommand<T> {
  Shell.PipableCommand {
    try await Shell.invoke { _, invocation in
      try await invocation.builtin { channel in
        try await channel.input.lines.reduce(into: initialResult, updateAccumulatingResult)
      }
    }
  }
}

public func reduce<T>(
  _ initialResult: T,
  _ nextPartialResult: @escaping (T, String) async throws -> T
) -> Shell.PipableCommand<T> {
  Shell.PipableCommand {
    try await Shell.invoke { _, invocation in
      try await invocation.builtin { channel in
        try await channel.input.lines.reduce(initialResult, nextPartialResult)
      }
    }
  }
}
