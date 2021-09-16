
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
      
      let sourceResult: Result<Void, Error>
      do {
        try await pipe.output.closeAfter {
          let sourceShell = subshell(output: Shell.Output(pipe.output))
          async let sourceResult: Void = try await source(sourceShell)
          try await sourceResult
        }
        sourceResult = .success(())
      } catch {
        sourceResult = .failure(error)
      }
      
      /// We allow the destination operation to terminate, but throw if the source destination failed
      let returnValue = try await destinationResult
      try sourceResult.get()
      return returnValue
    }
  }
  
}
