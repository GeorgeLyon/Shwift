
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
    stackSize: Int = 65536
  ) -> Self {
    let stack = UnsafeMutableBufferPointer<CChar>.allocate(capacity: stackSize)
    stack.initialize(repeating: 0)
    print("\(#filePath):\(#line)")
    defer {
      print("\(#filePath):\(#line)")
      stack.deallocate()
    }
    let top = stack.baseAddress! + stack.count
    print("""
      STACK: \(stack.baseAddress!) \(stack.count) \(top)
      """)
    let id: pid_t = withoutActuallyEscaping(operation) { operation in
      print("\(#filePath):\(#line)")
      return withUnsafePointer(to: operation) { operation in
        shwift_clone(
          { pointer in
            print("\(#filePath):\(#line):GEORGE")
            let operation = pointer!
              .bindMemory(to: (() -> CInt).self, capacity: 1)
              .pointee
            print("\(#filePath):\(#line)")
            return operation()
          },
          top,
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
    try throwIfPosixError(waitid(P_PID, id_t(id), &info, WEXITED | (block ? 0 : WNOHANG)))
    guard info[keyPath: pid] != 0 else {
      return nil
    }

    struct UncaughtSignal: Error {
      let signal: CInt
      let coreDumped: Bool
    }
    switch Int(info.si_code) {
    case Int(CLD_EXITED):
      print("\(#fileID):\(#line)")
      return info[keyPath: sigchldInfo].si_status
    case Int(CLD_KILLED):
      print("\(#fileID):\(#line):\(info[keyPath: killingSignal])")
      throw UncaughtSignal(signal: info[keyPath: killingSignal], coreDumped: false)
    case Int(CLD_DUMPED):
      print("\(#fileID):\(#line)")
      throw UncaughtSignal(signal: info[keyPath: killingSignal], coreDumped: true)
    default:
      fatalError()
    }
  }

  let id: pid_t
}

// MARK: - Memory Sharing

/**
 Allows mutating a single shared value across any processes spawned during `operation`. THIS IS EXTREMELY UNSAFE, as _only_ the bits of the value will be shared; any references in the value will _only_ exist in the process that created them. For example, setting this value to a `String` is unsafe, since a long enough string will be allocated on the heap, which is not shared between processes.
 */
func withVeryUnsafeInterprocess<T, U>(
  _ initialValue: T,
  operation: (inout T) async throws -> U
) async throws -> U {
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
  return try await(operation(&valuePointer.pointee))
}

// MARK: - Support

/**
 - warning: This type may be transferred over shared memory and thus cannot contain any heap-allocated values.
 */
struct PosixError: Swift.Error {
  let file: StaticString
  let line: UInt
  let column: UInt
  let returnValue: Int32
}

private func throwIfPosixError(
  _ returnValue: CInt,
  file: StaticString = #fileID,
  line: UInt = #line,
  column: UInt = #column
) throws {
  guard returnValue == 0 else {
    throw PosixError(file: file, line: line, column: column, returnValue: returnValue)
  }
}

public func foo(_ shell: Shell) async throws {
  // print("\(#filePath):\(#line)")
  try await shell.invoke { shell in
    // print("\(#filePath):\(#line)")
    let value: Int = try await withVeryUnsafeInterprocess(0) { shared in
      // print("\(#filePath):\(#line)")
      let monitor = try await FileDescriptorMonitor(in: shell)
      // print("\(#filePath):\(#line)")
      let process = Process.clone {
        // print("\(#filePath):\(#line)")
        sleep(1)
        // print("\(#filePath):\(#line)")
        shared = 3
        // print("\(#filePath):\(#line)")
        return 0
      }
      // print("\(#filePath):\(#line)")
      try! monitor.descriptor.close()
      // print("\(#filePath):\(#line)")
      try! await monitor.future.get()
      print("\(#filePath):\(#line)")
      print(try process.wait(block: false) as Any)
      print("\(#filePath):\(#line)")
      let result = shared
      return result
    }
    print(value)
  }
}