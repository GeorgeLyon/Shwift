import Foundation
import SystemPackage

/**
 An object which manages child processes
 */
public actor ChildProcessManager: InterruptHandler {

  /**
   - Parameters:
     - terminateManagedProcessesOnInterrupt: Terminates any child processes managed by this object if this process receives a `SIGINT`

   - warning: The first time a `ChildProcessManager` is created with `terminateManagedProcessesOnInterrupt` set to `true`, a signal handler will be registered for the `SIGINT` signal (and the signal mask for `SIGINT` will  be set to `SIG_IGN`). Signal handlers are global to the process, and if a different framework also handles `SIGINT` it is undefined which handler, or both, will be called. You can safely create multiple `ChildProcessManager`s with this option and when the last one is deinitialized, the signal mask for `SIGINT` will be reset to `SIG_DFL`. This will happen even if another framework calls `signal(SIGINT, SIG_IGN)` while this framework has registered a signal handler. If it is necessary to use another framework's `SIGINT` handler, you can omit this option and call `terminatedManagedProcesses` manually.
   */
  public init(
    terminateManagedProcessesOnInterrupt: Bool = false
  ) {
    if terminateManagedProcessesOnInterrupt {
      let interruptManager: InterruptManager = .shared
      self.interruptManager = interruptManager
      interruptManager.register(self)
    } else {
      interruptManager = nil
    }
  }

  deinit {
    precondition(managedProcesses.isEmpty)
    interruptManager?.unregister(self)
  }

  public func runManagedProcess(
    workingDirectory: String,
    environmentValues: [String: String],
    input: FileDescriptor,
    output: FileDescriptor,
    error: FileDescriptor,
    executable: FilePath,
    arguments: [String]
  ) async throws {
    let process = Process()
    let id = ObjectIdentifier(process)
    process.executableURL = URL(fileURLWithPath: executable.string)
    process.arguments = arguments
    process.environment = environmentValues
    process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
    process.standardInput = input.handle
    process.standardOutput = output.handle
    process.standardError = error.handle
    managedProcesses[id] = process
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      process.terminationHandler = { _ in continuation.resume() }
      do {
        try process.run()
        continuation.resume()
      } catch {
        continuation.resume(throwing: error)
      }
    }
    managedProcesses.removeValue(forKey: id)
    switch process.terminationReason {
    case .exit:
      break
    case .uncaughtSignal:
      throw Shell.Executable.Error.uncaughtSignal
    @unknown default:
      throw Shell.Executable.Error.unknown
    }
    guard process.terminationStatus == 0 else {
      throw Shell.Executable.Error
        .nonzeroTerminationStatus(process.terminationStatus)
    }
  }

  public func terminateManagedProcesses() {
    for process in managedProcesses.values {
      process.terminate()
    }
    managedProcesses.removeAll()
  }

  func handleInterrupt() async {
    terminateManagedProcesses()
  }

  private var managedProcesses: [ObjectIdentifier: Process] = [:]
  private let interruptManager: InterruptManager?
}

extension Shell.Executable {
  public enum Error: Swift.Error {
    case executableNotFound(String)
    case nonzeroTerminationStatus(CInt)
    case uncaughtSignal
    case unknown
  }
}

// MARK: - Convenience

private extension FileDescriptor {
  var handle: FileHandle {
    FileHandle(fileDescriptor: rawValue, closeOnDealloc: false)
  }
}
