
import Shell
import class Foundation.FileManager

import SystemPackage

@main
struct Script {
  static func main() async throws {
    let shell = Shell(
      workingDirectory: .init(FileManager.default.currentDirectoryPath),
      environment: [:],
      standardInput: .standardInput,
      standardOutput: .standardOutput,
      standardError: .standardError)
    let echo = Executable(path: "/bin/echo")
    
    for i in 0..<100 {
      try await shell.execute(echo, arguments: ["Foo", "Bar"])
    }
  }
}
