import XCTest
@testable import Shell

import Foundation

final class ShellTests: XCTestCase {
  
  func testMatrix() async throws {
    let cat = try shell.executable(named: "cat")!
    let echo = try shell.executable(named: "echo")!
    let abcPath = Bundle.module.path(forResource: "ABC", ofType: "txt")!
    typealias Operation = @Sendable (Shell) async throws -> Void
    
    let sources: [Operation] = [
      { shell in
        try await shell.execute(
          echo,
          arguments: [
            "ABC",
          ])
      },
      { shell in
        try await shell.execute(
          echo,
          arguments: [
            "-n",
            "ABC",
          ])
      },
      { shell in
        try await shell.execute(
          cat,
          arguments: [
            abcPath
          ])
      },
      { shell in
        try await shell.builtin { handle in
          try await handle.output.withTextOutputStream { stream in
            stream.write("ABC")
          }
        }
      },
      { shell in
        try await shell.builtin { handle in
          try await handle.output.withTextOutputStream { stream in
            stream.write("ABC\n")
          }
        }
      }
    ]
    
    for operation in sources {
      let lines: [String] = try await shell.pipe(operation) { shell in
        try await shell.builtin { handle in
          var lines: [String] = []
          for try await line in handle.input.lines {
            lines.append(line)
          }
          return lines
        }
      }
      print(lines)
    }
  }
  
  
  private let shell = Shell(
    directory: FilePath(FileManager.default.currentDirectoryPath),
    environment: ["PATH": ProcessInfo.processInfo.environment["PATH"]],
    input: .nullDevice,
    output: .standardOutput,
    error: .nullDevice,
    childProcessManager: ChildProcessManager())
}
