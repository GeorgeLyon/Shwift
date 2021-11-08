
import Shell
import Foundation

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
      print(String(repeating: "-", count: 40))
    }

    for i in 0..<100000 {
      printSeparator()
      do {
        try await shell.execute(echo, withArguments: ["\(i):", "Foo", "Bar"])

        printSeparator()

        _ = try await shell.pipe(
          .output,
          of: { shell in
            try? await shell.execute(echo, withArguments: ["\(i):", "Foo", "Bar"])
          },
          to: { shell in
            try await shell.builtin { handle in
              for try await line in handle.input.lines {
                try await handle.output.withTextOutputStream { stream in
                  print(line.replacingOccurrences(of: "Bar", with: "Baz"), to: &stream)
                }
              }
            }
          })
        
        printSeparator()

        _ = try await shell.pipe(
          .output,
          of: { shell in
            try? await shell.execute(echo, withArguments: ["\(i):", "Foo", "Bar"])
          },
          to: { shell in
            try await shell.execute(sed, withArguments: ["s/Bar/Baz/"])
          })

        printSeparator()
        
        _ = try await shell.pipe(
          .output,
          of: { shell in
            try? await shell
              /// `cat` may log to `stderr` once `xxd` closes its end of the pipe
              .subshell(standardError: .nullDevice)
              .execute(cat, withArguments: ["/dev/urandom"])
          },
          to: { shell in
            try await shell.pipe(
              .output,
              of: { shell in
                try? await shell
                  /// `xxd` may log to `stderr` once `head` closes its end of the pipe
                  .subshell(standardError: .nullDevice)
                  .execute(xxd, withArguments: [])
              },
              to: { shell in
                try await shell.execute(head, withArguments: ["-n2"])
              })
          })

          printSeparator()
      } catch {
        print(error)
      }
    }
  }
}

