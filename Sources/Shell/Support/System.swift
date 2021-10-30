
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

// MARK: - File Descriptor Monitoring

struct FileDescriptorMonitor {

  /**
   Creates a new `FileDescriptorMonitor`. The caller is responsible for ensuring that the `descriptor` of the resulting type is eventually closed.
   */
  init(in shell: Shell.InternalRepresentation) async throws {
    (descriptor, channel) = try await FileDescriptor.withPipe { pipe in
      let channel = try await shell.nioContext.withNullOutputDevice { nullOutput in
        try await NIOPipeBootstrap(group: shell.nioContext.eventLoopGroup)
          .channelInitializer { channel in
            final class ControlChannelHandler: ChannelInboundHandler {
              typealias InboundIn = ByteBuffer
              func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                fatalError()
              }
            }
            return channel.pipeline.addHandler(ControlChannelHandler())
          }
          .duplicating(
            inputDescriptor: pipe.readEnd,
            outputDescriptor: nullOutput)
      }
      return (try pipe.writeEnd.duplicate(), channel)
    }
  }

  /**
   The descriptor being monitored.
   */
  let descriptor: SystemPackage.FileDescriptor

  /**
   A future which completes when `descriptor` and any duplicates of `descriptor` are closed.
   */
  var future: EventLoopFuture<Void> { channel.closeFuture }

  private let channel: Channel

}

// MARK: - Process

/**
 Represents a process spawned from this process. When creating a process, it is the caller's responsibility to ensure that the process is eventually waited on (otherwise the child will never be reaped).
 */
struct Process {

  struct PosixSpawnFileActions {
    /**
     Creates a new `PosixSpawnFileActions`. The caller is responsible for ensuring `destroy` is eventually called on the resulting value.
     */
    init() throws {
      try throwIfPosixError(posix_spawn_file_actions_init(&c))
    }

    mutating func destroy() throws {
      try throwIfPosixError(posix_spawn_file_actions_destroy(&c))
    }

    mutating func addChangeDirectory(to path: FilePath) throws {
      try throwIfPosixError(path.withCString {
        posix_spawn_file_actions_addchdir_np(&c, $0)
      })
    }

    mutating func addDuplicate(
      _ source: SystemPackage.FileDescriptor, 
      to destination: SystemPackage.FileDescriptor
    ) throws {
      try throwIfPosixError(
        posix_spawn_file_actions_adddup2(&c, source.rawValue, destination.rawValue))
    }

    mutating func addClose(_ fileDescriptor: FileDescriptor) throws {
      try throwIfPosixError(
        posix_spawn_file_actions_addclose(&c, fileDescriptor.rawValue))
    } 

    #if canImport(Darwin)
    fileprivate var c: posix_spawn_file_actions_t!
    #elseif canImport(Glibc)
    fileprivate var c = posix_spawn_file_actions_t()
    #endif
  }

  struct PosixSpawnAttributes {
    /**
     Creates a new `PosixSpawnAttributes`. The caller is responsible for ensuring `destroy` is eventually called on the resulting value.
     */
    init() throws {
      try throwIfPosixError(posix_spawnattr_init(&c))
    }

    mutating func destroy() throws {
      try throwIfPosixError(posix_spawnattr_destroy(&c))
    }

    #if os(macOS)
    mutating func setCloseFileDescriptorsByDefault() throws {
      try throwIfPosixError(
        posix_spawnattr_setflags(&c, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)))
    }
    #endif

    #if canImport(Darwin)
    fileprivate var c: posix_spawnattr_t!
    #elseif canImport(Glibc)
    fileprivate var c = posix_spawnattr_t()
    #endif
  }

  static func spawn(
    executablePath: FilePath,
    actions: PosixSpawnFileActions,
    attributes: PosixSpawnAttributes,
    arguments: [String],
    environment: [(key: String, value: String)]
  ) throws -> Self {
    let cArguments = arguments.map { $0.withCString(strdup) }
    defer {
      for argument in cArguments {
        free(argument)
      }
    }
  
    let cEnvironment = environment.map { strdup("\($0)=\($1)") }
    defer {
      for value in cEnvironment {
        free(value)
      }
    }
    
    var id: pid_t = .zero
    try throwIfPosixError(
      executablePath.withPlatformString { executablePath in
        withUnsafePointer(to: actions.c) { actions in 
          withUnsafePointer(to: attributes.c) { attributes in 
          posix_spawn(
            &id,
            executablePath,
            actions,
            attributes,
            cArguments + [nil],
            cEnvironment + [nil])
          }
        }
      }
    )
    return Process(id: id)
  }

  #if canImport(Glibc)
  /**
   Clones this process and executes the provided operation.
   */
  static func clone(
    operation: () -> CInt,
    stackSize: Int = 4096
  ) -> Self {
    let stack = UnsafeMutableBufferPointer<CChar>.allocate(capacity: stackSize)
    defer { stack.deallocate() }
    let id = withoutActuallyEscaping(operation) { operation in
      withUnsafePointer(to: operation) { operation in
        shwift_clone(
          { pointer in
            let operation = pointer!
              .bindMemory(to: (() -> CInt).self, capacity: 1)
              .pointee
            return operation()
          },
          stack.baseAddress! + stack.count,
          SIGCHLD,
          UnsafeMutableRawPointer(mutating: operation))
      }
    }
    return Process(id: id)
  }
  #endif

  func terminate() throws {
    try throwIfPosixError(kill(id, SIGTERM))
  }
  
  /**
   Waits for the process to complete. If `block` is set to `false` (the default) and the process has not completed, this function will return `nil`.
   */
  func wait(block: Bool = false) throws -> CInt? {
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
    try throwIfPosixError(waitid(P_PID, id_t(id), &info, WEXITED | (block ? WNOHANG : 0)))
    guard info[keyPath: pid] != 0 else {
      return nil
    }

    switch Int(info.si_code) {
    case Int(CLD_EXITED):
      return info[keyPath: sigchldInfo].si_status
    case Int(CLD_KILLED):
      guard !Task.isCancelled else {
        throw CancellationError()
      }
      throw Error.uncaughtSignal(info[keyPath: killingSignal], coreDumped: false)
    case Int(CLD_DUMPED):
      throw Error.uncaughtSignal(info[keyPath: killingSignal], coreDumped: true)
    default:
      fatalError()
    }
  }

  private let id: pid_t
}

// MARK: - Memory Sharing

/**
 Allows mutating a single shared value across any processes spawned during `operation`. THIS IS EXTREMELY UNSAFE, as _only_ the bits of the value will be shared; any references in the value will _only_ exist in the process that created them. For example, setting this value to a `String` is unsafe, since a long enough string will be allocated on the heap, which is not shared between processes.
 */
func withVeryUnsafeInterprocess<T>(
  _ initialValue: T,
  operation: (inout T) async throws -> Void
) async throws -> T {
  let size = MemoryLayout<T>.size
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
  let valuePointer = pointer.bindMemory(to: T.self, capacity: 1)
  valuePointer.initialize(to: initialValue)
  try await(operation(&valuePointer.pointee))
  return valuePointer.pointee
}

// MARK: - Support

private enum Error: Swift.Error {
  case posixError(file: StaticString, line: UInt, column: UInt, returnValue: Int32)
  case uncaughtSignal(Int32, coreDumped: Bool)
}

private func throwIfPosixError(
  _ returnValue: CInt,
  file: StaticString = #fileID,
  line: UInt = #line,
  column: UInt = #column
) throws {
  guard returnValue == 0 else {
    throw Error
      .posixError(file: file, line: line, column: column, returnValue: returnValue)
  }
}
