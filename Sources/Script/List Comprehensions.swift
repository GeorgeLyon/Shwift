import Shwift

/**
 Converts shell input stream to output stream via transform.

 By default, input is segmented by newline, and a newline is printed at the end of each output segment.
 - Parameters:
 - delimiter: Character to split input into segments (defaults to newline)
 - terminator: String printed at the end of each output  (defaults to newline)
 - transform: converts String to String
 - Returns: ``Shell/PipableCommand``
 */
public func map(
  segmentingInputAt delimiter: Character = Builtin.Input.Lines.eol,
  withOutputTerminator terminator: String = Builtin.Input.Lines.eolStr,
  transform: @Sendable @escaping (String) async throws -> String
) -> Shell.PipableCommand<Void> {
  compactMap(segmentingInputAt: delimiter, withOutputTerminator: terminator, transform: transform)
}

/**
 Converts shell input stream to output stream via transform, ignoring nil input

 By default, input is segmented by newline, and a newline is printed at the end of each output segment.
 - Parameters:
 - delimiter: Character to split input into segments (defaults to newline)
 - terminator: String printed at the end of each output  (defaults to newline)
 - transform: converts String to String
 - Returns: ``Shell/PipableCommand``
 */
public func compactMap(
  segmentingInputAt delimiter: Character = Builtin.Input.Lines.eol,
  withOutputTerminator terminator: String = Builtin.Input.Lines.eolStr,
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

/**
 Returns the result of processing input elements using the given closure and mutable initial value to accumulate the result.
 - Parameters:
   - initialResult: mutable initial value to accumulate the result
   - delimiter: Character to split input into segments passed to closure (defaults to newline)
   - updateAccumulatingResult: A closure over the mutable accumulator and the next String.
 - Returns: ``Shell/PipableCommand``
*/
public func reduce<T>(
  into initialResult: T,
  segmentingInputAt delimiter: Character = Builtin.Input.Lines.eol,
  _ updateAccumulatingResult: @escaping (inout T, String) async throws -> Void
) -> Shell.PipableCommand<T> {
  Shell.PipableCommand {
    try await Shell.invoke { _, invocation in
      try await invocation.builtin { channel in
        try await channel.input.segmented(by: delimiter)
          .reduce(into: initialResult, updateAccumulatingResult)
      }
    }
  }
}

/**
 Returns the result of processing input elements using the given closure and mutable initial value to accumulate the result.
 - Parameters:
 - initialResult: initial value passed to initial closure
 - delimiter: Character to split input into segments passed to closure (defaults to newline)
 - nextPartialResult: A closure over the initial or previous value and the next String segment that returns the next value
 - Returns: ``Shell/PipableCommand``
 */
public func reduce<T>(
  _ initialResult: T,
  segmentingInputAt delimiter: Character = Builtin.Input.Lines.eol,
  _ nextPartialResult: @escaping (T, String) async throws -> T
) -> Shell.PipableCommand<T> {
  Shell.PipableCommand {
    try await Shell.invoke { _, invocation in
      try await invocation.builtin { channel in
        try await channel.input.segmented(by: delimiter).reduce(initialResult, nextPartialResult)
      }
    }
  }
}
