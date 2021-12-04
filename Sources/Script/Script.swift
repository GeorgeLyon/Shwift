import Shwift
import Dispatch
import SystemPackage

@_implementationOnly import class Foundation.FileManager

/**
 We consider the following to be part of our public API
 */
@_exported import ArgumentParser
@_exported import struct SystemPackage.FilePath
@_exported import struct Shwift.Environment
@_exported import struct Shwift.Input
@_exported import struct Shwift.Output
@_exported import struct Shwift.Process

// MARK: - Script

public protocol Script: ParsableCommand {
  func run() async throws

  /**
   The top level shell for this script.
   This value is read once prior to calling `run` and saved, so the execution of the script will not reflect changes to the root shell that happen after the Script has started running.

   By default, reads the current state of the this process.
   */
  var rootShell: Shell { get }

  /**
   Scripts can implement to run code before or after the body of the script has run, or post-process any errors encountered
   */
  func wrapInvocation<T>(
    _ invocation: () async throws -> T
  ) async throws -> T

  /**
   Called just before we attempt to launch a process.
   Can be used for logging.
   */
  func willLaunch(
    _ executable: Executable,
    withArguments arguments: [String],
    in workingDirectory: FilePath)

  /**
   Called if our attempt to launch an executable failed.
   Can be used for logging.
   */
  func didFailToLaunch(
    _ executable: Executable,
    withArguments arguments: [String],
    in workingDirectory: FilePath,
    dueTo error: Error)

  /**
   Called after we have launched a process.
   Can be used for logging.
   */
  func process(
    withID processID: Process.ID,
    didLaunchWith executable: Executable,
    arguments: [String],
    in workingDirectory: FilePath)

  /**
   Called after a process has terminated.
   Can be used for logging.
   */
  func process(
    withID processID: Process.ID,
    for executable: Executable,
    withArguments arguments: [String],
    in workingDirectory: FilePath,
    didComplete error: Error?)
}

extension Script {

  public var rootShell: Shell {
    Shell(
      workingDirectory: FilePath(FileManager.default.currentDirectoryPath),
      environment: .process,
      standardInput: .standardInput,
      standardOutput: .standardOutput,
      standardError: .standardError)
  }

  public func wrapInvocation<T>(
    _ invocation: () async throws -> T
  ) async throws -> T {
    try await invocation()
  }

}

// MARK: - Logging Default Implementations

extension Script {

  /**
   Called just before we attempt to launch a process.
   Can be used for logging.
   */
  public func willLaunch(
    _ executable: Executable,
    withArguments arguments: [String],
    in workingDirectory: FilePath
  ) {}

  /**
   Called if our attempt to launch an executable failed.
   Can be used for logging.
   */
  public func didFailToLaunch(
    _ executable: Executable,
    withArguments arguments: [String],
    in workingDirectory: FilePath,
    dueTo error: Error
  ) {}

  /**
   Called after we have launched a process.
   Can be used for logging.
   */
  public func process(
    withID processID: Process.ID,
    didLaunchWith executable: Executable,
    arguments: [String],
    in workingDirectory: FilePath
  ) {}

  /**
   Called after a process has terminated.
   Can be used for logging.
   */
  public func process(
    withID processID: Process.ID,
    for executable: Executable,
    withArguments arguments: [String],
    in workingDirectory: FilePath,
    didComplete error: Error?
  ) {}

}

// MARK: - Adapter for `ParsableCommand`

extension Script {

  public func run() throws {
    /// Work around for https://forums.swift.org/t/interaction-between-async-main-and-async-overloads/52171
    let box = ErrorBox()
    let sem = DispatchSemaphore(value: 0)
    Task {
      defer { sem.signal() }
      do {
        let shell = self.rootShell
        try await Shell.$hostScript.withValue(self) {
          try await Shell.$taskLocal.withValue(shell) {
            try await self.wrapInvocation {
              try await run()
            }
          }
        }
      } catch Process.TerminationError.nonzeroTerminationStatus(let status) {
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

// MARK: - Shell

public struct Shell {

  public init(
    workingDirectory: FilePath,
    environment: Environment,
    standardInput: Input,
    standardOutput: Output,
    standardError: Output
  ) {
    self.workingDirectory = workingDirectory
    self.environment = environment
    self.standardInput = standardInput
    self.standardOutput = standardOutput
    self.standardError = standardError
    self.context = Context()
  }

  fileprivate(set) var workingDirectory: FilePath
  fileprivate(set) var environment: Environment
  fileprivate(set) var standardInput: Input
  fileprivate(set) var standardOutput: Output
  fileprivate(set) var standardError: Output
  fileprivate let context: Context

  struct Invocation {
    let standardInput: FileDescriptor
    let standardOutput: FileDescriptor
    let standardError: FileDescriptor
    let context: Context

    /**
     Convenience for builtin invocations
     */
    func builtin<T>(
      _ command: (Builtin.Channel) async throws -> T
    ) async throws -> T {
      try await Builtin.withChannel(
        input: standardInput,
        output: standardOutput,
        in: context,
        command)
    }
  }

  static var current: Shell { taskLocal }

  static var scriptForLogging: Script { hostScript }

  static func invoke<T>(
    _ command: (Shell, Invocation) async throws -> T
  ) async throws -> T {
    let shell: Shell = .taskLocal
    return try await shell.standardInput.withFileDescriptor(in: shell.context) { input in
      try await shell.standardOutput.withFileDescriptor(in: shell.context) { output in
        try await shell.standardError.withFileDescriptor(in: shell.context) { error in
          try await command(
            shell,
            Invocation(
              standardInput: input,
              standardOutput: output,
              standardError: error,
              context: shell.context))
        }
      }
    }
  }

  @TaskLocal
  fileprivate static var taskLocal: Shell!

  @TaskLocal
  fileprivate static var hostScript: Script!

}

// MARK: - Subshell

public func subshell<T>(
  pushing path: FilePath? = nil,
  updatingEnvironmentWith environmentUpdates: [String: String?] = [:],
  standardInput: Input? = nil,
  standardOutput: Output? = nil,
  standardError: Output? = nil,
  operation: () async throws -> T
) async throws -> T {
  var shell: Shell = .current
  if let path = path {
    shell.workingDirectory.push(path)
  }
  for (name, value) in environmentUpdates {
    shell.environment[name] = value
  }
  if let standardInput = standardInput {
    shell.standardInput = standardInput
  }
  if let standardOutput = standardOutput {
    shell.standardOutput = standardOutput
  }
  if let standardError = standardError {
    shell.standardError = standardError
  }
  return try await Shell.$taskLocal.withValue(shell, operation: operation)
}

@_disfavoredOverload
public func subshell<T>(
  pushing path: FilePath? = nil,
  updatingEnvironmentWith environmentUpdates: [String: String?] = [:],
  standardInput: Input? = nil,
  standardOutput: Output? = nil,
  standardError: Output? = nil,
  operation: @escaping () async throws -> T
) -> Shell.PipableCommand<T> {
  Shell.PipableCommand {
    try await subshell(
      pushing: path,
      updatingEnvironmentWith: environmentUpdates,
      standardInput: standardInput,
      standardOutput: standardOutput,
      standardError: standardError,
      operation: operation)
  }
}

// MARK: - Shell State

/**
 The current working directory of the current `Script`.
 */
public var workingDirectory: FilePath {
  Shell.current.workingDirectory
}

public var environment: Environment {
  Shell.current.environment
}
