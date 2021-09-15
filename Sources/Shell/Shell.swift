
import SystemPackage

/**
 We consider `FilePath` to be part of our public API
 */
@_exported import struct SystemPackage.FilePath

/// TODO: Sendable conformance is unchecked until the compiler gets better post Swift 5.5
public struct Shell: @unchecked Sendable {
  
  /**
   Creates a `Shell`.
   */
  public init(
    directory: FilePath,
    environment: Environment,
    input: Input,
    output: Output,
    error: Output,
    childProcessManager: ChildProcessManager = ChildProcessManager(terminateManagedProcessesOnInterrupt: true))
  {
    self.directory = directory
    self.environment = environment
    self.input = input
    self.output = output
    self.error = error
    self.childProcessManager = childProcessManager
  }
  
  public func subshell(
    pushing path: FilePath? = nil,
    environment: Environment? = nil,
    updatingEnvironmentValues newEnvironmentValues: KeyValuePairs<String, String?>? = nil,
    input: Input? = nil,
    output: Output? = nil,
    error: Output? = nil
  ) -> Shell {
    var environment = environment ?? self.environment
    if let newEnvironmentValues = newEnvironmentValues {
      environment.set(newEnvironmentValues)
    }
    return Shell(
      directory: path.map(directory.pushing) ?? directory,
      environment: environment,
      input: input ?? self.input,
      output: output ?? self.output,
      error: error ?? self.error,
      childProcessManager: childProcessManager)
  }
  
  public let directory: FilePath
  public let environment: Environment
  public let input: Input
  public let output: Output
  public let error: Output
  
  public let childProcessManager: ChildProcessManager
  
  let builtinContext = Builtin.Context()
  
}
