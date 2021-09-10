
public struct Shell: Sendable {
  
  public func subshell(
    environment: Environment? = nil,
    updatingEnvironmentValues newEnvironmentValues: KeyValuePairs<String, String?>? = nil
  ) -> Shell {
    var environment = environment ?? self.environment
    if let newEnvironmentValues = newEnvironmentValues {
      environment.set(newEnvironmentValues)
    }
    return Shell(
      environment: environment,
      childProcessManager: childProcessManager)
  }
  
  public let environment: Environment
  public let directory: Directory
  public let input: Input
  public let output: Output
  public let error: Output
  
  public let childProcessManager: ChildProcessManager
  
}
