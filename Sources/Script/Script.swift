
import Shell
import Foundation

public protocol Script {
  
}

// MARK: - Shell

public extension Script {
  
  var shell: Shell { .current }
  
  func subshell<T>(_ body: () async throws -> T) async rethrows -> T {
    let subshell = shell.subshell()
    return try await Shell.withSubshell(subshell, operation: body)
  }
  
}

extension Shell {
  
  static var process: Shell {
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
    .taskLocal ?? .process
  }
  
  static func withSubshell<T>(
    _ subshell: Shell,
    operation: () async throws -> T
  ) async rethrows -> T {
    try await $taskLocal.withValue(subshell, operation: operation)
  }
  
  @TaskLocal
  private static var taskLocal: Shell?
}

private extension ChildProcessManager {
  
  static let shared = ChildProcessManager(terminateManagedProcessesOnInterrupt: true)
}
