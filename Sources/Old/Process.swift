#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
import CLinuxSupport
#else
#error("Unsupported Platform")
#endif

@_implementationOnly import NIO
import SystemPackage

enum Process {

  /**
   A failure encountered while spawning a child process.

   - warning: On Linux, we spawn processes using `clone`/`execve`. We need to perform certain fallible tasks in the cloned process prior to executing the desired executable. To report faillures, we transmit a value of `Process.Error` using shared memory from the cloned child to the parent. **This is very unsafe**. Great care should be taken to ensure that `Process.Error` is safe to transmit in this manner. Specifically, it should not contain any references to heap-allocated storage which may be only valid in the cloned process. A simple example of such problematic types is `String`, since its underlying storage may be allocated on the heap.
   */
  struct SpawnError: Swift.Error {
    /// `StaticString` is statically allocated and thus safe to share.
    let file: StaticString
    /// Integer data types are plain-old-data-types and thus safe to share across clones.
    let line: UInt
    let column: UInt

    /// An enum whose associated types are all safe to share across clones should itself be safely shareable.
    enum Kind {
      /**
       Arbitrary error types are **NOT** safe to share across clones since they could reference arbitrary heap-allocated storage. In order to provide some information about the failure, we can transfer the type (which is statically allocated) across clones.
       */
      case untransferrable(Swift.Error.Type)

      /**
       An operation returned a nonzero status code. 
       Integer data types are plain-old-data-types and thus safe to share across clones.
       */
      case nonzeroReturnValue(CInt, errno: CInt)
    }
    let kind: Kind
  }

  /**
   An error which caused a spawned process to terminate
   */
  enum TerminationError: Swift.Error {
    /**
     Waiting on the process failed.
     */
    case waitFailed(returnValue: CInt, errno: CInt)

    /**
     The monitored file descriptor was closed prior to process termination.
     */
    case monitorClosedPriorToProcessTermination

    /**
     The process terminated successfully, but the termination status was nonzero.
     */
    case nonzeroTerminationStatus(CInt)

    /**
      The process terminated due to an uncaught signal.
      */
    case uncaughtSignal(CInt, coreDumped: Bool)
  }

  static func run(
    executablePath: FilePath,
    arguments: [String],
    in shell: Shell.InternalRepresentation
  ) async throws {
    #if canImport(Darwin)
    fatalError()
    #elseif canImport(Glibc)
    try await withVeryUnsafeShared(SpawnError.self) { sharedError in
      do {
        try await shell.monitorProcessUsingFileDescriptor(name: executablePath.lastComponent!.string) { monitor in
          let id = clone {
            print("\(#filePath):\(#line) - \(executablePath.lastComponent!.string)")

            /**
            Helper functions for reporting errors encountered in the cloned process
            */
            func check<T>(
              file: StaticString = #filePath,
              line: UInt = #line,
              column: UInt = #column,
              _ operation: () throws -> T
            ) -> T {
              do {
                return try operation()
              } catch {
                sharedError = SpawnError(
                  file: file, 
                  line: line, 
                  column: column,
                  kind: .untransferrable(type(of: error)))
                exit(-1)
              }
            }
            func check(
              file: StaticString = #filePath,
              line: UInt = #line,
              column: UInt = #column,
              _ returnValue: CInt
            ) {
              if returnValue != 0 {
                sharedError = SpawnError(
                  file: file,
                  line: line,
                  column: column, 
                  kind: .nonzeroReturnValue(returnValue, errno: errno))
                exit(-1)
              }
            }

            /**
             The following may seem convoluted but we need to support the case where we switch two file descriptors. For instance, mapping standard out to standard error and standard error to standard out.
             */
            do {
              /// These are the file descriptors we want set when we launch the executable
              let reservedFileDescriptors: Set<FileDescriptor> = [
                .standardInput,
                .standardOutput,
                .standardError,
                monitorFileDescriptor
              ]
              /// Create temporary file descriptors to map from
              func duplicateAsTemporary(_ descriptor: FileDescriptor) -> FileDescriptor {
                while true {
                  let descriptor = check { try descriptor.duplicate() }
                  if !reservedFileDescriptors.contains(descriptor) {
                    return descriptor
                  }
                }
              }
              let fileDescriptorMappings: [FileDescriptor: FileDescriptor] = check {
                [
                  duplicateAsTemporary(shell.standardInput): .standardInput,
                  duplicateAsTemporary(shell.standardOutput): .standardOutput,
                  duplicateAsTemporary(shell.standardError): .standardError,
                  duplicateAsTemporary(monitor): monitorFileDescriptor,
                ]
              }
              let openFileDescriptors = check { try FileDescriptor.openFileDescriptors }
              for descriptor in openFileDescriptors {
                if !fileDescriptorMappings.keys.contains(descriptor) {
                  check { try descriptor.close() }
                }
              }
              for (source, target) in fileDescriptorMappings {
                precondition(source != target)
                check {
                  let descriptor = try source.duplicate(as: target)
                  precondition(descriptor == target)
                }
                check { try source.close() }
              }
            }

            /// Change the working directory
            check(shell.workingDirectory.withPlatformString(chdir))

            check(executablePath.withPlatformString { path in
              execve(
                path,
                /// Since this process will either be replaced or immediately exit, we don't need to free these values.
                ([executablePath.string] + arguments).map { $0.withCString(strdup) } + [nil], 
                shell.environment.map { strdup("\($0)=\($1)") } + [nil])
            })
            fatalError()
          }
          return id
        }
      } catch {
        /// `sharedError` should supercede any other thrown errors
        throw sharedError ?? error
      }
      if let error = sharedError {
        throw error
      }
    }
    #endif
  }
}

// MARK: - Support

// MARK: File Descriptor Monitoring

private extension Shell.InternalRepresentation {

  /**
   Creates a file descriptor which is valid during `operation`, then waits for that file descriptor and any duplicates to close (including duplicates created as the result of spawning a new process).
   */
  func monitorProcessUsingFileDescriptor(
    name: String,
    _ operation: (FileDescriptor) async throws -> pid_t
  ) async throws {
    let (channel, processID) = try await FileDescriptor.withPipe { pipe -> (Channel, pid_t) in
      let channel = try await nioContext.withNullOutputDevice { nullOutput in
        try await NIOPipeBootstrap(group: nioContext.eventLoopGroup)
          .channelInitializer { channel in
            return channel.pipeline.addHandler(FileDescriptorMonitorHandler())
          }
          .duplicating(
            inputDescriptor: pipe.readEnd,
            outputDescriptor: nullOutput)
      }
      return (channel, try await operation(pipe.writeEnd))
    }
    try await withTaskCancellationHandler(
      handler: {
        let returnValue = kill(processID, SIGTERM)
        precondition(returnValue == 0)
      }, 
      operation: {
        print("\(#filePath):\(#line) - \(processID): \(name)")
        try await channel.closeFuture.get()
        print("\(#filePath):\(#line) - \(processID): \(name)")
      })
    /**
     Ideally, we would not block here, but it seems that monitored file descriptor closing and the process becoming waitable does not happen atomically. So, most of the time this call shouldn't block, but some of the time it can block momentarily while Linux process management catches up.
     */
    try Process.wait(on: processID, canBlock: true)
  }

  /**
    - note: The main purpose of `Handler` is to detect if a child process accidentally ends up writing to the file descriptor we are using for monitoring. This situation seems highly unlikely but since we are using a specific file descriptor (3) which is visible to the child through other mechansims (like `/proc/self/fd`), it is prudent to detect if we encounter this error.
    */
  private final class FileDescriptorMonitorHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
      fatalError()
    }
  }

}

/**
 File descriptor to use for the monitor in the child process.
 */
private var monitorFileDescriptor = FileDescriptor(rawValue: max(STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO) + 1)

// MARK: Waiting on a Process

extension Process {

  /**
   Waits on the process. This call is nonblocking and expects that the process represented by `processID` has already terminated
   */
  fileprivate static func wait(on processID: pid_t, canBlock: Bool) throws {
    /// Some key paths are different on Linux and macOS
    #if canImport(Darwin)
    let pid = \siginfo_t.si_pid
    let sigchldInfo = \siginfo_t.self
    let killingSignal = \siginfo_t.si_status
    #elseif canImport(Glibc)
    let pid = \siginfo_t._sifields._sigchld.si_pid
    let sigchldInfo = \siginfo_t._sifields._sigchld
    let killingSignal = \siginfo_t._sifields._rt.si_sigval.sival_int
    #endif
    
    var info = siginfo_t()
    /**
     We use a process ID of `0` to detect the case when the child is not in a waitable state.
     Since we use the control channel to detect termination, this _shouldn't_ happen (unless the child decides to call `close(3)` for some reason).
     */
    info[keyPath: pid] = 0
    do {
      errno = 0
      let returnValue = waitid(P_PID, id_t(processID), &info, WEXITED | (canBlock ? 0 : WNOHANG))
      guard returnValue == 0 else {
        throw TerminationError.waitFailed(returnValue: returnValue, errno: errno)
      }
    }
    guard info[keyPath: pid] != 0 else {
      throw TerminationError.monitorClosedPriorToProcessTermination
    }

    switch Int(info.si_code) {
    case Int(CLD_EXITED):
      let terminationStatus = info[keyPath: sigchldInfo].si_status
      guard terminationStatus == 0 else {
        throw TerminationError.nonzeroTerminationStatus(terminationStatus)
      }
    case Int(CLD_KILLED):
      throw TerminationError.uncaughtSignal(info[keyPath: killingSignal], coreDumped: false)
    case Int(CLD_DUMPED):
      throw TerminationError.uncaughtSignal(info[keyPath: killingSignal], coreDumped: true)
    default:
      fatalError()
    }
  }
}

// MARK: - Support (Linux)
#if canImport(Glibc)

// MARK: Sharing Memory

/**
 Allows mutating a single shared value across any processes spawned during `operation`. THIS IS EXTREMELY UNSAFE, as _only_ the bits of the value will be shared; any references in the value will _only_ exist in the process that created them. For example, setting this value to a `String` is unsafe, since a long enough string will be allocated on the heap, which is not shared between processes.
 */
private func withVeryUnsafeShared<Value, Outcome>(
  _ type: Value.Type,
  operation: (inout Value?) async throws -> Outcome
) async throws -> Outcome {
  let size = MemoryLayout<Value?>.size
  let pointer = mmap(
    nil,
    size,
    PROT_READ | PROT_WRITE,
    MAP_ANONYMOUS | MAP_SHARED,
    -1,
    0)!
  precondition(pointer != MAP_FAILED)
  defer { 
    let returnValue = munmap(pointer, size)
    precondition(returnValue == 0)
  }
  let valuePointer = pointer.bindMemory(to: Value?.self, capacity: 1)
  valuePointer.initialize(to: .none)
  return try await(operation(&valuePointer.pointee))
}

// MARK: Spawning a new process

private extension Process {

  /**
   Clones this process and executes the provided operation.
   */
  static func clone(
    operation: () -> CInt,
    stackSize: Int = 65536
  ) -> pid_t {
    queue.sync {
      let stack = UnsafeMutableBufferPointer<CChar>.allocate(capacity: stackSize)
      stack.initialize(repeating: 0)
      defer { stack.deallocate() }
      let stackTop = stack.baseAddress! + stack.count
      return withoutActuallyEscaping(operation) { operation in
        return withUnsafePointer(to: operation) { operation in
          shwift_clone(
            { pointer in
              let operation = pointer!
                .bindMemory(to: (() -> CInt).self, capacity: 1)
                .pointee
              return operation()
            },
            stackTop,
            SIGCHLD,
            UnsafeMutableRawPointer(mutating: operation))
        }
      }
    }
  }

}

import Foundation
private let queue = DispatchQueue(label: #filePath)
#endif