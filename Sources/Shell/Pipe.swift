
extension Shell {
  
  public enum OutputChannel {
    case output, error
  }

  public func pipe<SourceOutcome, DestinationOutcome>(
    _ outputChannel: OutputChannel,
    of source: (Shell) async throws -> SourceOutcome,
    to destination: (Shell) async throws -> DestinationOutcome
  ) async throws -> (source: SourceOutcome, destination: DestinationOutcome) {
    
    try await invoke { invocation in
      let pipe = try FileDescriptor.pipe()
      
      let sourceShell = Shell(
        workingDirectory: workingDirectory,
        environment: environment,
        standardInput: .unmanaged(invocation.standardInput),
        standardOutput: .unmanaged(pipe.writeEnd),
        standardError: .unmanaged(invocation.standardError),
        nioContext: nioContext)
      async let sourceOutcome: SourceOutcome = {
        defer { try! pipe.writeEnd.close() }
        return try await source(sourceShell)
      }()
      
      let destinationShell = Shell(
        workingDirectory: workingDirectory,
        environment: environment,
        standardInput: .unmanaged(pipe.readEnd),
        standardOutput: .unmanaged(invocation.standardOutput),
        standardError: .unmanaged(invocation.standardError),
        nioContext: nioContext)
      async let destinationOutcome: DestinationOutcome = {
        defer { try! pipe.readEnd.close() }
        return try await destination(destinationShell)
      }()
      
      return (try await sourceOutcome, try await destinationOutcome)
    }
  }
}
