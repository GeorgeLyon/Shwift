
import Shwift
import SystemPackage

// MARK: - Echo

/**
 Prints a set of items to the specified shell output
 
 The API is meant to mirror `Swift.print`.
 */
public func echo(
  _ items: Any...,
  separator: String = " ",
  terminator: String = "\n"
) async throws {
  try await echo(items: items, separator: separator, terminator: terminator)
}

/**
 Prints a set of items to the specified shell output
 
 The API is meant to mirror `Swift.print`.
 */
@_disfavoredOverload
public func echo(
  _ items: Any...,
  separator: String = " ",
  terminator: String = "\n"
) -> Shell.PipableCommand<Void> {
  Shell.PipableCommand {
    try await echo(items: items, separator: separator, terminator: terminator)
  }
}

private func echo(
  items: [Any],
  separator: String = " ",
  terminator: String = "\n"
) async throws {
  try await Shell.invoke { shell, invocation in
    try await invocation.builtin { channel in
      try await channel.output.withTextOutputStream { stream in
        /// We can't use `print` because it does not accept an array
        items
          .flatMap { [String(describing: $0), separator] }
          .dropLast()
          .forEach { stream.write($0) }
        stream.write(terminator)
      }
    }
  }
}

// MARK: - Cat

public func cat(to output: Output) async throws {
  try await Shell.invoke { _, invocation in
    try await output.withFileDescriptor(in: invocation.context) { output in
      struct Stream: TextOutputStream {
        let fileDescriptor: FileDescriptor
        var result: Result<Void, Error> = .success(())
        mutating func write(_ string: String) {
          guard case .success = result else {
            return
          }
          var mutableString = string
          do {
            _ = try mutableString.withUTF8 { buffer in
              try fileDescriptor.write(UnsafeRawBufferPointer(buffer))
            }
          } catch {
            result = .failure(error)
          }
        }
      }
      var stream = Stream(fileDescriptor: output)
      try await invocation.builtin { handle in
        for try await line in handle.input.lines {
          print(line, to: &stream)
          try stream.result.get()
        }
      }
    }
  }
}
