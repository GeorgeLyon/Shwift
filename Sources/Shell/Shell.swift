
import SystemPackage

public struct Shell: Sendable {
  
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
  
  let builtinEngine = BuiltinEngine()
  
}
