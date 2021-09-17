
import Shell
import Foundation

/**
 We consider ArgumentParser part of our API
 */
@_exported import ArgumentParser

// MARK: - Script

public protocol Script: ParsableCommand {
  var rootShell: Shell { get }
  func run() async throws
}

extension Script {
  
  public var shell: Shell { .current }
  
  public func subshell<T>(
    pushing path: FilePath? = nil,
    environment: Shell.Environment? = nil,
    updatingEnvironmentValues newEnvironmentValues: KeyValuePairs<String, String?>? = nil,
    input: Shell.Input? = nil,
    output: Shell.Output? = nil,
    error: Shell.Output? = nil,
    operation: () async throws -> T
  ) async rethrows -> T {
    let subshell = shell.subshell(
      pushing: path,
      environment: environment,
      updatingEnvironmentValues: newEnvironmentValues,
      input: input,
      output: output,
      error: error)
    return try await Shell.withSubshell(subshell, operation: operation)
  }
  
  public var rootShell: Shell { .process }
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
  
  static var current: Shell {
    /**
     We want to call `rootShell` every time we access it to potentially pick up process working directory changes.
     */
    taskLocal ?? hostScript.rootShell
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
