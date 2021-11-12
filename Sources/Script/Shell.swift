
@_implementationOnly import Foundation

extension Shell {
  
  /**
   A shell representing the current state of the process.
   
   Changing the process working directory will not change the working directory of a shell after it is created.
   */
  public static var process: Shell {
    /**
     We need to create a new shell every time so that we pick up the correct working directory
     */
    Shell(
      workingDirectory: FilePath(FileManager.default.currentDirectoryPath),
      environment: ProcessInfo.processInfo.environment,
      standardInput: .standardInput,
      standardOutput: .standardOutput,
      standardError: .standardError)
  }
  
}
