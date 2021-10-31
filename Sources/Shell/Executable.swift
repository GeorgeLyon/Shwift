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

        #if canImport(Darwin)
        /// `setCloseFileDescriptorsByDefault` is only available on Apple platforms
        try attributes.setCloseFileDescriptorsByDefault()
        let process = try Process.spawn(
          executablePath: path, 
          actions: actions, 
          attributes: attributes, 
          arguments: [path.string] + arguments, 
          environment: shell.environment.map { $0 })
        #elseif canImport(Glibc)
        /**
         On Linux platforms, we need to emulate `setCloseFileDescriptorsByDefault`.
         
         - note: `swift-corelibs-foundation` also emulates this setting (https://github.com/apple/swift-corelibs-foundation/blob/08979ae37953be8d8b2d75622f16de33f274939c/Sources/Foundation/Process.swift#L957) but there is a subtle race condition in its implementation. Specifically, a new file descriptor may be opened (or an existing one closed) after we list all the file descriptors but before we call `posix_spawn`. To work around this issue, we first `clone` this process, which copies all file descriptors but stops any concurrent code, and then add the `close` calls manually in the cloned process. We then call `posix_spawn` from the cloned process and return the result, propagating the pid of the child using shared memory.
         */
        let process: Process
        do {
          print("\(#fileID):\(#line):\(path)")
          do {
            process = try await withVeryUnsafeInterprocess(Result<pid_t, PosixError>?.none) { sharedResult in
              print("\(#fileID):\(#line):\(path)")
              let monitor = try await FileDescriptorMonitor(in: shell)

              let test = Process.clone {
                print("GEORGE!")
                return 0
              }
              print(try test.wait(block: true) as Any)

              let helper = Process.clone {
                do {
                  print("\(#fileID):\(#line):\(path)")
                  /// Manually close all file descriptors we don't want to explicitly pass to the child
                  let exclude: Set = [
                    STDIN_FILENO, 
                    STDOUT_FILENO, 
                    STDERR_FILENO,
                    controlFileDescriptor.rawValue,
                  ]
                  let directory = opendir("/proc/self/fd")!
                  print("\(#fileID):\(#line):\(path)")
                  defer { closedir(directory) }
                  while let entry = readdir(directory) {
                    print("\(#fileID):\(#line):\(path)")
                    let name = withUnsafeBytes(of: entry.pointee.d_name) { cName in
                      String(
                        decoding: cName.prefix(while: { $0 != 0 }), 
                        as: Unicode.UTF8.self)
                    }
                    guard let descriptor = CInt(name), !exclude.contains(descriptor) else {
                      continue
                    }
                    print("\(#fileID):\(#line):\(path):closing \(descriptor)")
                    try actions.addClose(FileDescriptor(rawValue: descriptor))
                  }

                  print("\(#fileID):\(#line):\(path)")
                  let process = try Process.spawn(
                    executablePath: path,
                    actions: actions, 
                    attributes: attributes, 
                    arguments: [path.string] + arguments, 
                    environment: shell.environment.map { $0 })
                  print("\(#fileID):\(#line):\(path)")
                  sharedResult = .success(process.id)
                  return 0
                } catch let error as PosixError {
                  print("\(#fileID):\(#line):\(path)")
                  sharedResult = .failure(error)
                  return -1
                } catch {
                  print("UNSUPPORTED ERROR: \(error)")
                  return -2
                }
              }
              print("\(#fileID):\(#line):\(path)")
              try! monitor.descriptor.close()
              print("\(#fileID):\(#line):\(path)")
              try! await monitor.future.get()
              print("\(#fileID):\(#line):\(path)")
              let returnValue = try helper.wait()!
              print("\(#fileID):\(#line):\(path)")
              switch (returnValue, sharedResult) {
              case (0, .success(let id)):
                return Process(id: id)
              case (-1, .failure(let error)):
                throw error
              default:
                fatalError()
              }
            }
          } catch {
            try monitor.descriptor.close()
            throw error
          }
        }
        #endif
        
        /// These operations shouldn't be able to fail, and if they do we would still need to wait on `process` so just crash for now.
        do {
          try! monitor.descriptor.close()
          await withTaskCancellationHandler(
            handler: { try! process.terminate() },
            operation: {
              try! await monitor.future.get()
            })
        }

        if Task.isCancelled {
          /// Reap the child process, discarding the termination status
          _ = try? process.wait()!
          throw CancellationError()
        } else {
          /// Because we waited for `monitor` to complete, the process should have already exited.
          terminationStatus = try process.wait()!
        }
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
