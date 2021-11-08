
import Shell
import Dispatch
import SystemPackage
import class Foundation.FileManager
import class Foundation.ProcessInfo

/**
 We consider `ArgumentParser` and `Shell` part of our public API
 */
@_exported import ArgumentParser
@_exported import Shell

// MARK: - Script

public protocol Script: ParsableCommand {
  func withRootShell<T>(operation: @escaping (Shell) async throws -> T) async throws -> T
  func run() async throws
}

extension Script {
  
  public func subshell<T>(
    pushing path: FilePath? = nil,
    updatingEnvironmentWith environmentUpdates: [String: String?] = [:],
    standardInput: Shell.Input? = nil,
    standardOutput: Shell.Output? = nil,
    standardError: Shell.Output? = nil,
    operation: @escaping () async throws -> T
  ) async throws -> T {
    try await Shell.withCurrent { shell in
      var environment = shell.environment
      for (key, value) in environmentUpdates {
        environment[key] = value
      }
      let subshell = shell.subshell(
        pushing: path,
        replacingEnvironmentWith: environment,
        standardInput: standardInput,
        standardOutput: standardOutput,
        standardError: standardError)
      return try await Shell.withSubshell(subshell, operation: operation)
    }
  }
  
  @_disfavoredOverload
  public func subshell<T>(
    pushing path: FilePath? = nil,
    updatingEnvironmentWith environmentUpdates: [String: String?] = [:],
    standardInput: Shell.Input? = nil,
    standardOutput: Shell.Output? = nil,
    standardError: Shell.Output? = nil,
    operation: @escaping () async throws -> T
  ) -> Shell._Invocation<T> {
    Shell._Invocation {
      try await subshell(
        pushing: path,
        updatingEnvironmentWith: environmentUpdates,
        standardInput: standardInput,
        standardOutput: standardOutput,
        standardError: standardError,
        operation: operation)
    }
  }
  
  public var workingDirectory: FilePath {
    get async throws {
      try await Shell.withCurrent { shell in
        shell.workingDirectory
      }
    }
  }
  
  public func withRootShell<T>(
    operation: @escaping (Shell) async throws -> T
  ) async throws -> T {
    try await operation(.process)
  }
}

extension Script {
  
  public func run() throws {
    /// Work around for https://forums.swift.org/t/interaction-between-async-main-and-async-overloads/52171
    let box = ErrorBox()
    let sem = DispatchSemaphore(value: 0)
    Task {
      do {
        try await Shell.$hostScript.withValue(self) {
          try await run()
        }
      } catch Shell.Process.TerminationError.nonzeroTerminationStatus(let status) {
        /// Convert `Shell` error into one that `ArgumentParser` understands
        box.error = ExitCode(rawValue: status)
      } catch let error as SystemPackage.Errno {
        /// Convert `SystemPackage` error into one that `ArgumentParser` understands
        box.error = ExitCode(rawValue: error.rawValue)
      }
      sem.signal()
    }
    sem.wait()
    if let error = box.error {
      throw error
    }
  }
  
}

private final class ErrorBox {
  var error: Error? = nil
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
      workingDirectory: FilePath(FileManager.default.currentDirectoryPath),
      environment: ProcessInfo.processInfo.environment,
      standardInput: .standardInput,
      standardOutput: .standardOutput,
      standardError: .standardError)
  }
  
  public static func withCurrent<T>(
    operation: @escaping (Shell) async throws -> T
  ) async throws -> T {
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
