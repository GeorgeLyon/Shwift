import Shwift
import SystemPackage

// MARK: - Resolving Executables

public func executable(named name: String) async throws -> Executable {
  guard let executable = try await executable(named: name, required: false) else {
    struct ExecutableNotFound: Error {
      let name: String
    }
    throw ExecutableNotFound(name: name)
  }
  return executable
}

/**
- Parameters:
 - required: Should only ever be set to `false`, implying the initializer returns `nil` if the specified executable is not found.
*/
public func executable(named name: String, required: Bool) async throws -> Executable? {
  precondition(required == false)
  let path = Shell.current.environment.searchForExecutables(named: name).matches.first
  return path.map(Executable.init)
}

// MARK: - Invoking Executables by Name

public func execute(_ executableName: String, _ arguments: String?...) async throws {
  try await execute(executableName, arguments: arguments)
}

public func execute(_ executableName: String, arguments: [String?]) async throws {
  try await executable(named: executableName)(arguments: arguments)
}

@_disfavoredOverload
public func execute(
  _ executableName: String,
  _ arguments: String?...
) async throws -> Shell.PipableCommand<Void> {
  try await execute(executableName, arguments: arguments)
}

@_disfavoredOverload
public func execute(
  _ executableName: String,
  arguments: [String?]
) async throws -> Shell.PipableCommand<Void> {
  Shell.PipableCommand {
    try await execute(executableName, arguments: arguments)
  }
}

// MARK: - Invoking Executables

public struct Executable {
  public let path: FilePath
  public init(path: FilePath) {
    self.path = path
  }

  public func callAsFunction(_ arguments: String?...) async throws {
    try await callAsFunction(arguments: arguments)
  }

  public func callAsFunction(arguments: [String?]) async throws {
    try await Shell.invoke { shell, invocation in
      struct Logger: ProcessLogger {
        let executable: Executable
        let arguments: [String]
        let shell: Shell

        func failedToLaunchProcess(dueTo error: Error) {
          Shell.scriptForLogging
            .didFailToLaunch(
              executable,
              withArguments: arguments,
              in: shell.workingDirectory,
              dueTo: error)
        }

        func didLaunch(_ process: Process) {
          Shell.scriptForLogging
            .process(
              withID: process.id,
              didLaunchWith: executable,
              arguments: arguments,
              in: shell.workingDirectory)
        }

        func willWait(on process: Process) {

        }

        func process(_ process: Process, didTerminateWithError error: Error?) {
          Shell.scriptForLogging
            .process(
              withID: process.id,
              for: executable,
              withArguments: arguments,
              in: shell.workingDirectory,
              didComplete: error)
        }
      }
      /**
       - note: In shell scripts, specifying an environment variable which is not defined as an argument effectively skips that argument. For instance `echo Foo $NOT_DEFINED Bar` would be analogous to `echo Foo  Bar`. We mirror this behavior in Script by allowing arguments to be `nil`.
       */
      let arguments = arguments.compactMap { $0 }
      Shell.scriptForLogging
        .willLaunch(
          self,
          withArguments: arguments,
          in: shell.workingDirectory)
      try await Process.run(
        executablePath: path,
        arguments: arguments.compactMap { $0 },
        environment: shell.environment,
        workingDirectory: shell.workingDirectory,
        fileDescriptorMapping: .init(
          standardInput: invocation.standardInput,
          standardOutput: invocation.standardOutput,
          standardError: invocation.standardError),
        logger: Logger(executable: self, arguments: arguments, shell: shell),
        in: invocation.context)

    }
  }

  @_disfavoredOverload
  public func callAsFunction(_ arguments: String?...) async throws -> Shell.PipableCommand<Void> {
    Shell.PipableCommand {
      try await callAsFunction(arguments: arguments)
    }
  }

  @_disfavoredOverload
  public func callAsFunction(arguments: [String?]) async throws -> Shell.PipableCommand<Void> {
    Shell.PipableCommand {
      try await callAsFunction(arguments: arguments)
    }
  }
}
