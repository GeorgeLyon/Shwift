
import SystemPackage

extension Shell {
  
  public func pipe<T>(
    _ source: @Sendable (Shell) async throws -> Void,
    to destination: @Sendable (Shell) async throws -> T
  ) async throws -> T {
    let pipe = try FileDescriptor.openPipe()
    return try await pipe.input.closeAfter {
      let destinationShell = subshell(input: Shell.Input(pipe.input))
      async let destinationResult = try await destination(destinationShell)
      try await pipe.output.closeAfter {
        let sourceShell = subshell(output: Shell.Output(pipe.output))
        async let sourceResult: Void = try await source(sourceShell)
        try await sourceResult
      }
      return try await destinationResult
    }
  }
  
}
