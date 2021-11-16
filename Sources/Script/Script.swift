
import Shwift
import Dispatch
import SystemPackage

@_implementationOnly import class Foundation.FileManager

/**
 We consider `ArgumentParser` and `Shell` part of our public API
 */
@_exported import ArgumentParser
@_exported import struct Shwift.Environment
@_exported import struct Shwift.Input
@_exported import struct Shwift.Output
@_exported import struct Shwift.Process

// MARK: - Script

public protocol Script: ParsableCommand {
  func run() async throws
  
  /**
   The working directory this script runs in.
   This value is read once prior to calling `run` and saved.
   
   By default, the process working directory.
   */
  var rootWorkingDirectory: FilePath { get }
  
  /**
   The environment the script runs in.
   This value is read once prior to calling `run` and saved.
   
   By default, the process working environment.
   */
  var rootEnvironment: Environment { get }
  
  /**
   Run an operation with the IO for this script. `operation` should not write to the `IO` channels after it returns (this allows a script to, for instance, open a file and direct the output there).
   
   By default, this uses the standard input, output and error of the proess
   */
  func withIO<T>(
    _ operation: (Shell.IO) async throws -> T
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
  
  public var rootWorkingDirectory: FilePath {
    FilePath(FileManager.default.currentDirectoryPath)
  }
  
  public var rootEnvironment: Environment { .process }
  
  public func withIO<T>(
    _ operation: (Shell.IO) async throws -> T
  ) async throws -> T {
    let io = Shell.IO(
      standardInput: .standardInput,
      standardOutput: .standardOutput,
      standardError: .standardError)
    return try await operation(io)
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
  ) { }
  
  /**
   Called if our attempt to launch an executable failed.
   Can be used for logging.
   */
  public func didFailToLaunch(
    _ executable: Executable,
    withArguments arguments: [String],
    in workingDirectory: FilePath,
    dueTo error: Error
  ) { }
  
  /**
   Called after we have launched a process.
   Can be used for logging.
   */
  public func process(
    withID processID: Process.ID,
    didLaunchWith executable: Executable,
    arguments: [String],
    in workingDirectory: FilePath
  ) { }
  
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
  ) { }
  
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
        let context = Context()
        try await withIO { io in
          let shell = Shell(
            workingDirectory: rootWorkingDirectory,
            environment: rootEnvironment,
            io: io,
            context: context)
          try await Shell.$hostScript.withValue(self) {
            try await Shell.$taskLocal.withValue(shell) {
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
  
  public struct IO {
    public init(
      standardInput: Input,
      standardOutput: Output,
      standardError: Output
    ) {
      self.standardInput = standardInput
      self.standardOutput = standardOutput
      self.standardError = standardError
    }
    
    public fileprivate(set) var standardInput: Input
    public fileprivate(set) var standardOutput: Output
    public fileprivate(set) var standardError: Output
  }
  
  fileprivate(set) var workingDirectory: FilePath
  fileprivate(set) var environment: Environment
  fileprivate var io: IO
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
    return try await shell.io.standardInput.withFileDescriptor(in: shell.context) { input in
      try await shell.io.standardOutput.withFileDescriptor(in: shell.context) { output in
        try await shell.io.standardError.withFileDescriptor(in: shell.context) { error in
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
    shell.io.standardInput = standardInput
  }
  if let standardOutput = standardOutput {
    shell.io.standardOutput = standardOutput
  }
  if let standardError = standardError {
    shell.io.standardError = standardError
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

