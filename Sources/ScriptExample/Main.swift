
import Shell
import Foundation

import SystemPackage

@main
struct Script {
  static func main() async throws {
    struct Logger: ShellLogger {
      func willLaunch(
        _ executable: Executable,
        withArguments arguments: [String],
        in workingDirectory: FilePath
      ) {
        print("Launching \(executable.name)...")
      }
      
      public func process(
        _ process: Shell.Process,
        didLaunchWith executable: Executable,
        arguments: [String],
        in workingDirectory: FilePath
      ) {
        print("Launched \(executable.name) (\(process.id.rawValue))")
      }

      public func process(
        _ process: Shell.Process,
        for executable: Executable,
        withArguments arguments: [String],
        in workingDirectory: FilePath,
        didComplete error: Error?
      ) {
        if let error = error {
          print("Completed \(executable.name) (\(process.id.rawValue)) with error: \(error)")
        } else {
          print("Completed \(executable.name) (\(process.id.rawValue))")
        }
      }
    }
    let shell = Shell(
      workingDirectory: .init(FileManager.default.currentDirectoryPath),
      environment: ["PATH": ProcessInfo.processInfo.environment["PATH"]!],
      standardInput: .nullDevice,
      standardOutput: .standardOutput,
      standardError: .standardError,
      logger: Logger())
    
    let echo = try shell.executable(named: "echo")
    let cat = try shell.executable(named: "cat")
    let sed = try shell.executable(named: "sed")
    let xxd = try shell.executable(named: "xxd")
    let head = try shell.executable(named: "head")

    func printSeparator() {
      let pipe = try! FileDescriptor.pipe()
      defer { 
        try! pipe.readEnd.close()
        try! pipe.writeEnd.close()
      }
      print(String(repeating: "-", count: 40) + "(\(pipe.readEnd.rawValue))")
    }

    for i in 0..<100000 {
      printSeparator()
      do {
        try await shell.execute(echo, arguments: ["\(i):", "Foo", "Bar"])

        printSeparator()

        _ = try await shell.pipe(
          .output,
          of: { shell in
            try? await shell.execute(echo, arguments: ["\(i):", "Foo", "Bar"])
          },
          to: { shell in
            try await shell.builtin { handle in
              for try await line in handle.input.lines {
                try await handle.output.withTextOutputStream { stream in
                  print(line.replacingOccurrences(of: "Bar", with: "Baz"), to: &stream)
                }
              }
            }
//            try await shell.execute(sed, arguments: ["s/Bar/Baz/"])
          })

        printSeparator()
        
        _ = try await shell.pipe(
          .output,
          of: { shell in
            try? await shell
              /// `cat` may log to `stderr` once `xxd` closes its end of the pipe
              .subshell(standardError: .nullDevice)
              .execute(cat, arguments: ["/dev/urandom"])
          },
          to: { shell in
            try await shell.pipe(
              .output,
              of: { shell in
                try? await shell
                  /// `xxd` may log to `stderr` once `head` closes its end of the pipe
                  .subshell(standardError: .nullDevice)
                  .execute(xxd, arguments: [])
              },
              to: { shell in
                try await shell.execute(head, arguments: ["-n2"])
              })
          })

          printSeparator()
      } catch {
        print(error)
      }
    }
  }
}
