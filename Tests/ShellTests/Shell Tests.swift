import XCTest
@testable import Shell

import Foundation

final class ShellTests: XCTestCase {
  
  func testMatrix() async throws {
    let cat = try shell.executable(named: "cat")!
    let echo = try shell.executable(named: "echo")!
    let sed = try shell.executable(named: "sed")!
    let abcPath = Bundle.module.path(forResource: "ABC", ofType: "txt")!
    
    struct Operation {
      init(line: Int = #line, body: @escaping @Sendable (Shell) async throws -> Void) {
        self.line = line
        self.body = body
      }
      let line: Int
      let body: @Sendable (Shell) async throws -> Void
    }
    
    let sources: [Operation] = [
      Operation { shell in
        try await shell.execute(
          echo,
          arguments: [
            "ABC",
          ])
      },
      Operation { shell in
        try await shell.execute(
          echo,
          arguments: [
            "-n",
            "ABC",
          ])
      },
      Operation { shell in
        try await shell.execute(
          cat,
          arguments: [
            abcPath
          ])
      },
      Operation { shell in
        try await shell.read(from: FilePath(abcPath))
      },
      Operation { shell in
        try await shell.builtin { handle in
          try await handle.output.withTextOutputStream { stream in
            print("ABC", to: &stream)
          }
        }
      }
    ]
    
    let destinations: [Operation] = [
      Operation { shell in
        for _ in 0..<2 {
          try await shell.execute(
            echo,
            arguments: [
              "-n",
              "ABC",
            ])
        }
      },
      Operation { shell in
        try await shell.execute(
          sed,
          arguments: [
            #"s/\(.*\)/\1\1/"#,
          ])
      },
      Operation { shell in
        try await shell.builtin { handle in
          for try await line in handle.input.lines {
            try await handle.output.withTextOutputStream { stream in
              print("\(line)\(line)", to: &stream)
            }
          }
        }
      }
    ]
    
    let matrix = sources.flatMap { source in
      destinations.map { destination in
        (source, destination)
      }
    }
    
    for (source, destination) in matrix {
      do {
        let test = { @Sendable (shell: Shell) in
          try await shell.pipe(source.body, to: destination.body)
        }
        let lines: [String] = try await shell.pipe(test) { shell in
          try await shell.builtin { handle in
            var lines: [String] = []
            for try await line in handle.input.lines {
              lines.append(line)
            }
            return lines
          }
        }
        XCTAssertEqual(lines, ["ABCABC"], "Failed piping \(source.line) to \(destination.line)")
      } catch {
        XCTFail("Failed piping \(source.line) to \(destination.line) due to \(error)")
      }
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
