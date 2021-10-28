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
      case posixError(file: StaticString, line: UInt, column: UInt, returnValue: Int32)
      case controlChannelClosedPriorToTermination
      case uncaughtSignal(Int32, coreDumped: Bool)
      case nonzeroTerminationStatus(Int)
    }
    
    func execute(
      arguments: [String],
      in shell: Shell.State
    ) async throws {
      
      let cArguments = ([path.string] + arguments).map { $0.withCString(strdup) }
      defer {
        for argument in cArguments {
          free(argument)
        }
      }
    
      let cEnvironment = shell.environment.map { strdup("\($0)=\($1)") }
      defer {
        for value in cEnvironment {
          free(value)
        }
      }
      
      /// Unfortunately, `posix_spawn_file_actions_t` and `posix_spawnattr_t` declaration is different across the different platforms.
      #if canImport(Darwin)
      var actions: posix_spawn_file_actions_t!
      var attributes: posix_spawnattr_t!
      #elseif canImport(Glibc)
      var actions = posix_spawn_file_actions_t()
      var attributes = posix_spawnattr_t()
      #else
      #error("Unsupported Platform")
      #endif
      
      try throwIfPosixError(posix_spawn_file_actions_init(&actions))
      defer { posix_spawn_file_actions_destroy(&actions) }
      try throwIfPosixError(posix_spawnattr_init(&attributes))
      defer { posix_spawnattr_destroy(&attributes) }
      
      /// `Foundation.Process` always sets this flag, but we want to avoid doing so so signals like interrupts are also sent to children
      // try throwIfPosixError(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)))
        
      #if canImport(Darwin)
      try throwIfPosixError(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT)))
      #else
      #warning("POSIX_SPAWN_CLOEXEC_DEFAULT is not supported on this platform")
      #endif
    
      try throwIfPosixError(shell.workingDirectory.withCString {
        posix_spawn_file_actions_addchdir_np(&actions, $0)
      })
    
      try throwIfPosixError(
        posix_spawn_file_actions_adddup2(&actions, shell.standardInput.rawValue, STDIN_FILENO))
      try throwIfPosixError(
        posix_spawn_file_actions_adddup2(&actions, shell.standardOutput.rawValue, STDOUT_FILENO))
      try throwIfPosixError(
        posix_spawn_file_actions_adddup2(&actions, shell.standardError.rawValue, STDERR_FILENO))
      
      let (controlChannel, processID) = try await FileDescriptor.withPipe { controlPipe -> (Channel, pid_t) in
        
        /**
         Duplicate the control file descriptor into the child process, so we can monitor the child process for termination without blocking.
         */
        try throwIfPosixError(
          posix_spawn_file_actions_adddup2(&actions, controlPipe.writeEnd.rawValue, controlFileDescriptor))
        
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
              inputDescriptor: controlPipe.readEnd,
              outputDescriptor: nullOutput)
        }
        
        var processID: pid_t = .zero
        try throwIfPosixError(
          path.withPlatformString { executablePath in
            posix_spawn(
              &processID,
              executablePath,
              &actions,
              &attributes,
              cArguments + [nil],
              cEnvironment + [nil])
          }
        )
        
        return (channel, processID)
      }
      
      try await withTaskCancellationHandler(
        handler: {
          try! throwIfPosixError(kill(processID, SIGTERM))
        },
        operation: {
           try await controlChannel.closeFuture.get()
          
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
          try throwIfPosixError(waitid(P_PID, id_t(processID), &info, WEXITED | WNOHANG))
          guard info[keyPath: pid] != 0 else {
            throw Error.controlChannelClosedPriorToTermination
          }

          switch Int(info.si_code) {
          case Int(CLD_EXITED):
            let status = info[keyPath: sigchldInfo].si_status
            guard status == 0 else {
              /**
               A nonzero termination status might be interpreted by the caller, so cast the status to `Int`
               */
              throw Executable.Error.nonzeroTerminationStatus(Int(status))
            }
            /// The process completed successfully
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
        })
    }
      
  }
  
}

// MARK: - Support

private func throwIfPosixError(
  _ returnValue: CInt,
  file: StaticString = #fileID,
  line: UInt = #line,
  column: UInt = #column
) throws {
  guard returnValue == 0 else {
    throw Executable.Error
      .posixError(file: file, line: line, column: column, returnValue: returnValue)
  }
}

/// Practically, this should always be `3`, but formulate it this way to be safer
private var controlFileDescriptor = max(STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO) + 1
