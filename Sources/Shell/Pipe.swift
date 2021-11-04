
#if canImport(Darwin)
import let Darwin.SIGPIPE
#elseif canImport(Glibc)
import let Glibc.SIGPIPE
#endif


extension Shell {
  
  public enum OutputChannel {
    case output, error
  }

  public func pipe<T>(
    _ outputChannel: OutputChannel,
    of source: (Shell) async throws -> Void,
    to destination: (Shell) async throws -> T
  ) async throws -> T {
    
    try await invoke { invocation in
      let pipe = try FileDescriptor.pipe()
      
      let sourceShell = Shell(
        workingDirectory: workingDirectory,
        environment: environment,
        standardInput: .unmanaged(invocation.standardInput),
        standardOutput: .unmanaged(pipe.writeEnd),
        standardError: .unmanaged(invocation.standardError),
        nioContext: nioContext)
      async let sourceOutcome: Void = {
        defer { try! pipe.writeEnd.close() }
        do {
          return try await source(sourceShell)
        } catch Process.TerminationError.uncaughtSignal(SIGPIPE, coreDumped: false) {
          /// It is OK for the source invocation to terminate because it is writing to a closed pipe.
          return ()
        }
      }()
      
      let destinationShell = Shell(
        workingDirectory: workingDirectory,
        environment: environment,
        standardInput: .unmanaged(pipe.readEnd),
        standardOutput: .unmanaged(invocation.standardOutput),
        standardError: .unmanaged(invocation.standardError),
        nioContext: nioContext)
      async let destinationOutcome: T = {
        defer { try! pipe.readEnd.close() }
        return try await destination(destinationShell)
      }()
      
      try await sourceOutcome
      return try await destinationOutcome
    }
  }
    

    
}
