
import Shell
import Foundation

/**
 We consider ArgumentParser part of our API
 */
@_exported import ArgumentParser

// MARK: - Script

public protocol Script: ParsableCommand {
  func withRootShell<T>(operation: (Shell) async throws -> T) async rethrows -> T
  func run() async throws
}

extension Script {
  public func subshell<T>(
    pushing path: FilePath? = nil,
    environment: Shell.Environment? = nil,
    updatingEnvironmentValues newEnvironmentValues: KeyValuePairs<String, String?>? = nil,
    input: Shell.Input? = nil,
    output: Shell.Output? = nil,
    error: Shell.Output? = nil,
    operation: () async throws -> T
  ) async rethrows -> T {
    try await Shell.withCurrent { shell in
      let subshell = shell.subshell(
        pushing: path,
        environment: environment,
        updatingEnvironmentValues: newEnvironmentValues,
        input: input,
        output: output,
        error: error)
      return try await Shell.withSubshell(subshell, operation: operation)
    }
  }
  
  public func withRootShell<T>(operation: (Shell) throws -> T) rethrows -> T {
    try operation(.process)
  }
  public func withRootShell<T>(operation: (Shell) async throws -> T) async rethrows -> T {
    try await operation(.process)
  }
}

extension Script {
  
  public static func main() throws {
    var command = try (self as ParsableCommand.Type).parseAsRoot()
    if let script = command as? Script {
      /// Work around for https://forums.swift.org/t/interaction-between-async-main-and-async-overloads/52171
      Task {
        do {
          try await Shell.$hostScript.withValue(script) {
            try await script.run()
          }
        } catch Shell.Executable.Error.nonzeroTerminationStatus(let status) {
          exit(withError: ExitCode(rawValue: status))
        } catch {
          exit(withError: error)
        }
        exit()
      }
      dispatchMain()
    } else {
      /// Behave like `ParsableCommand`
      do {
        try command.run()
      } catch {
        exit(withError: error)
      }
    }
  }
}

// MARK: - Shell

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
      directory: FilePath(FileManager.default.currentDirectoryPath),
      environment: .process,
      input: .standardInput,
      output: .standardOutput,
      error: .standardError)
  }
  
  public static func withCurrent<T>(operation: (Shell) async throws -> T) async rethrows -> T {
    if let taskLocal = taskLocal {
      return try await operation(taskLocal)
    } else {
      return try await hostScript.withRootShell(operation: operation)
    }
  }
  
  static func withSubshell<T>(
    _ subshell: Shell,
    operation: () async throws -> T
  ) async rethrows -> T {
    return try await $taskLocal.withValue(subshell, operation: operation)
  }
  
  @TaskLocal
  private static var taskLocal: Shell!
  
  @TaskLocal
  fileprivate static var hostScript: Script!
}
