
import Shell
import Dispatch
import SystemPackage
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
      defer { sem.signal() }
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
      } catch {
        box.error = error
      }
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

// MARK: - Current Shell

extension Shell {
  
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
