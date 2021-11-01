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
    
    func execute(
      arguments: [String],
      in shell: Shell.InternalRepresentation
    ) async throws {
        /// Great caution should be taken to ensure that `SharedError` is safe to share across cloned processes.
        struct SharedError: Swift.Error {
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
        try await withVeryUnsafeShared(SharedError.self) { sharedError in
          let process: Process = try await shell.withMonitoredFileDescriptor { monitor in
            Process.clone {
              func check<T>(
                file: StaticString = #filePath,
                line: UInt = #line,
                column: UInt = #column,
                _ operation: () throws -> T
              ) -> T {
                do {
                  return try operation()
                } catch {
                  sharedError = SharedError(
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
                  sharedError = SharedError(
                    file: file,
                    line: line,
                    column: column, 
                    kind: .nonzeroReturnValue(returnValue, errno: errno))
                  exit(-1)
                }
              }

              /// Set up file descriptors
              let mappedFileDescriptors: [FileDescriptor: FileDescriptor] = [
                .standardInput: shell.standardInput,
                .standardOutput: shell.standardOutput,
                .standardError: shell.standardError,
              ]
              for (target, source) in mappedFileDescriptors {
                check(try source.duplicate(as: target))
              }

              /**
              Now that we are in a clone, we can safely iterate over our open file descriptors without worrying about about race conditions related to the opening or closing of file descriptors.
              */
              check(try FileDescriptor.openFileDescriptors
                .filter { !mappedFileDescriptors.keys.contains($0) }
                .forEach(FileDescriptor.close))

              /// Change the working directory
              check(shell.workingDirectory.withPlatformString(chdir))

              check(path.withPlatformString { path in
                execve(
                  path,
                  /// Since this process will either be replaced or immediately exit, we don't need to free these values.
                  arguments.map { $0.withCString(strdup) }, 
                  environment.map { strdup("\($0)=\($1)") })
              })
              fatalError()
            }
          }
          /// At this point, the cloned process should have completed and `shared` should be set to a valid value.
          if let error = sharedError {
            throw error
          }
          let terminationStatus = try process.wait()
          
        }
        return process
      }
      print("\(#fileID):\(#line)")
      let terminationStatus = try process.wait()!
      print("\(#fileID):\(#line)")
      guard terminationStatus == 0 else {
        throw Executable.Error.nonzeroTerminationStatus(Int(terminationStatus))
      }
    }

    func execute2(
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
        let process: Process = try await withVeryUnsafeInterprocess(Result<pid_t, PosixError>?.none) { sharedResult in
          let monitor = try await FileDescriptorMonitor(in: shell)
          let helper = Process.clone {
            do {
              /// Manually close all file descriptors we don't want to explicitly pass to the child
              let exclude: Set = [
                STDIN_FILENO, 
                STDOUT_FILENO, 
                STDERR_FILENO,
                controlFileDescriptor.rawValue,
              ]
              let directory = opendir("/proc/self/fd")!
              defer { closedir(directory) }
              while let entry = readdir(directory) {
                let name = withUnsafeBytes(of: entry.pointee.d_name) { cName in
                  String(
                    decoding: cName.prefix(while: { $0 != 0 }), 
                    as: Unicode.UTF8.self)
                }
                guard let descriptor = CInt(name), !exclude.contains(descriptor) else {
                  continue
                }
                try actions.addClose(FileDescriptor(rawValue: descriptor))
              }

              let process = try Process.spawn(
                executablePath: path,
                actions: actions, 
                attributes: attributes, 
                arguments: [path.string] + arguments, 
                environment: shell.environment.map { $0 })
              sharedResult = .success(process.id)
              return 0
            } catch let error as PosixError {
              sharedResult = .failure(error)
              return -1
            } catch {
              print("UNSUPPORTED ERROR: \(error)")
              return -2
            }
          }
          try! monitor.descriptor.close()
          try! await monitor.future.get()
          let returnValue = try helper.wait()!
          switch (returnValue, sharedResult) {
          case (0, .success(let id)):
            return Process(id: id)
          case (-1, .failure(let error)):
            throw error
          default:
            fatalError()
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
private var monitorFileDescriptor = FileDescriptor(rawValue: max(STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO) + 1)
private var controlFileDescriptor = FileDescriptor(rawValue: max(STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO) + 1)
