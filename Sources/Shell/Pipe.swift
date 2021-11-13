
extension Shell {
  
  public enum OutputChannel {
    case output, error
  }

  public func pipe<SourceOutcome, DestinationOutcome>(
    _ outputChannel: OutputChannel,
    of source: (Shell) async throws -> SourceOutcome,
    to destination: (Shell) async throws -> DestinationOutcome
  ) async throws -> (source: SourceOutcome, destination: DestinationOutcome) {
    
    try await withIO { invocation in
      let pipe = try FileDescriptor.pipe()
      
      let sourceShell: Shell
      switch outputChannel {
      case .output:
        sourceShell = subshell(standardOutput: .unmanaged(pipe.writeEnd))
      case .error:
        sourceShell = subshell(standardError: .unmanaged(pipe.writeEnd))
      }
      async let sourceOutcome: SourceOutcome = {
        defer { try! pipe.writeEnd.close() }
        return try await source(sourceShell)
      }()
      
      let destinationShell = subshell(standardInput: .unmanaged(pipe.readEnd))
      async let destinationOutcome: DestinationOutcome = {
        defer { try! pipe.readEnd.close() }
        return try await destination(destinationShell)
      }()
      
      let sourceResult: Result<SourceOutcome, Error>
      do {
        sourceResult = .success(try await sourceOutcome)
      } catch {
        sourceResult = .failure(error)
      }

      let destinationResult: Result<DestinationOutcome, Error>
      do {
        destinationResult = .success(try await destinationOutcome)
      } catch {
        destinationResult = .failure(error)
      }

      return (try sourceResult.get(), try destinationResult.get())
    }
  }
}
