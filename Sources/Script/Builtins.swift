
import Shell

public extension Script {
  
  /**
   Prints a set of items to the specified shell output
   
   The API is meant to mirror `Swift.print`.
   */
  func echo(
    _ items: Any...,
    separator: String = " ",
    terminator: String = "\n",
    to outputType: Shell.OutputType = .output
  ) -> Shell._Invocation<Void> {
    Shell._Invocation { shell in
      try await shell.builtin { handle in
        let target: Builtin.Output
        switch outputType {
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
  
}

public extension Shell {
  /**
   A type used for selecting a particular flavor of output
   */
  enum OutputType {
    case output
    case error
  }
}
