#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#else
#error("Unsupported Platform")
#endif

import SystemPackage
@_implementationOnly import NIO

public typealias Executable = Shell.Executable

extension Shell {
  
  public func execute(_ executable: Executable, arguments: [String]) async throws {
    try await invoke { state in
      try await executable.execute(arguments: arguments, in: state)
    }
  }
  
  public struct Executable {
    
    public init(path: FilePath) {
      self.path = path
    }
    
    public let path: FilePath
  
    public enum Error: Swift.Error {
      case nonzeroTerminationStatus(Int)
    }
    
    func execute(
      arguments: [String],
      in shell: Shell.InternalRepresentation
    ) async throws {
      var actions = try Process.PosixSpawnFileActions()
      defer { try! actions.destroy() }
      var attributes = try Process.PosixSpawnAttributes()
      defer { try! attributes.destroy() }
        
      try actions.addChangeDirectory(to: shell.workingDirectory)
      try actions.addDuplicate(shell.standardInput, to: .standardInput)
      try actions.addDuplicate(shell.standardOutput, to: .standardOutput)
      try actions.addDuplicate(shell.standardError, to: .standardError)

      let monitor = try await FileDescriptorMonitor(in: shell)
      let terminationStatus: CInt
      do {
        try actions.addDuplicate(monitor.descriptor, to: controlFileDescriptor)
        try attributes.setCloseFileDescriptorsByDefault()
        let process = try Process.spawn(
          executablePath: path, 
          actions: actions, 
          attributes: attributes, 
          arguments: [path.string] + arguments, 
          environment: shell.environment.map { $0 })
        
        /// These operations shouldn't be able to fail, and if they do we would still need to wait on `process` so just crash for now.
        do {
          try! monitor.descriptor.close()
          await withTaskCancellationHandler(
            handler: { try! process.terminate() },
            operation: {
              try! await monitor.future.get()
            })
        }

        /// Because we waited for `monitor` to complete, the process should have already exited.
        terminationStatus = try process.wait()!
      } catch {
        try! monitor.descriptor.close()
        throw error
      }
      
      guard terminationStatus == 0 else {
        throw Executable.Error.nonzeroTerminationStatus(Int(terminationStatus))
      }
    }
  }
  
}

// MARK: - Support

/// Practically, this should always be `3`, but formulate it this way to make it more explicit.
private var controlFileDescriptor = FileDescriptor(rawValue: max(STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO) + 1)
