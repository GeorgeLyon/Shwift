import XCTest
import SystemPackage
@testable import Shell

import Foundation

final class ShellTests: XCTestCase {

  func testExecutable() throws {
    try XCTAssertOutput(
      of: { shell in
        let echo = try shell.executable(named: "echo")
        try await shell.execute(echo, withArguments: ["Echo"])
      },
      is: """
      Echo

      """)
    
    try XCTAssertOutput(
      of: { shell in
        let cat = try shell.executable(named: "cat")
        try await shell.execute(cat, withArguments: [self.supportFilePath])
      },
      is: """
      Cat

      """)
    
    try XCTAssertOutput(
      of: { shell in
        let echo = try shell.executable(named: "echo")
        let cat = try shell.executable(named: "cat")
        try await shell.execute(echo, withArguments: ["Echo"])
        try await shell.execute(cat, withArguments: [self.supportFilePath])
      },
      is: """
      Echo
      Cat

      """)
  }
  
  func testBuiltinOutput() throws {
    try XCTAssertOutput(
      of: { shell in
        try await shell.builtin { handle in
          try await handle.output.withTextOutputStream { stream in
            print("Builtin", to: &stream)
          }
        }
      },
      is: """
      Builtin
      
      """)
  }
  
  func testMatrix() throws {

    struct Operation {
      init(
        line: UInt = #line,
        body: @escaping (Shell) async throws -> Void
      ) {
        self.line = line
        self.body = body
      }
      let line: UInt
      let body: (Shell) async throws -> Void
    }

    let sources = [
      Operation { shell in
        let echo = try shell.executable(named: "echo")
        try await shell.execute(echo, withArguments: ["Cat"])
      },
      Operation { shell in
        let cat = try shell.executable(named: "cat")
        try await shell.execute(cat, withArguments: [self.supportFilePath])
      },
      Operation { shell in
        try await shell.builtin { handle in
          try await handle.output.withTextOutputStream { stream in
            print("Cat", to: &stream)
          }
        }
      },
//      Operation { shell in
//        try await shell.read(from: FilePath(self.supportFilePath))
//      },
    ]

    let destinations = [
      Operation { shell in
        let sed = try shell.executable(named: "sed")
        try await shell.execute(sed, withArguments: ["s/a/aa/"])
      },
      Operation { shell in
        try await shell.builtin { handle in
          for try await line in handle.input.lines {
            try await handle.output.withTextOutputStream { stream in
              print(line.description.replacingOccurrences(of: "a", with: "aa"), to: &stream)
            }
          }
        }
      },
      /// Piping `source` the following operation causes a failure as `source` never returns
//      Operation { shell in
//        try await shell.builtin { handle in
//          try await handle.output.withTextOutputStream { stream in
//            print("Caat", to: &stream)
//          }
//        }
//      },
    ]

    let matrix = sources.flatMap { source in
      destinations.map { destination in
        (source, destination)
      }
    }

    for (source, destination) in matrix {
      do {
        try XCTAssertOutput(
          of: { shell in
            _ = try await shell.pipe(
              .output,
              of: source.body,
              to: destination.body)
          },
          is: """
          Caat
          
          """,
          message: """
            Failed piping \(source.line) to \(destination.line)
            """,
          line: source.line)
      } catch {
        XCTFail("Failed piping \(source.line) to \(destination.line) due to \(error)")
      }
    }
  }
  
  private func XCTAssertOutput(
    of operation: @escaping (Shell) async throws -> Void,
    is output: String,
    message: @escaping @autoclosure () -> String = "",
    file: StaticString = #file, line: UInt = #line,
    function: StaticString = #function
  ) throws {
    let shell = Shell(
      workingDirectory: FilePath(FileManager.default.currentDirectoryPath),
      environment: [
        "PATH": ProcessInfo.processInfo.environment["PATH"]
      ].compactMapValues { $0 },
      standardInput: .nullDevice,
      standardOutput: .standardOutput,
      standardError: .standardError)
    let e1 = expectation(description: "\(function):\(line) \(message())")
    let e2 = expectation(description: "\(function):\(line) \(message())")
    
    let pipe = try FileDescriptor.pipe()
    Task {
      try await pipe.writeEnd.closeAfter {
        let subshell = shell.subshell(standardOutput: .unmanaged(pipe.writeEnd))
        try await operation(subshell)
        e1.fulfill()
      }
    }
    Task {
      try pipe.readEnd.closeAfter {
        let outputHandle = FileHandle(fileDescriptor: pipe.readEnd.rawValue, closeOnDealloc: false)
        XCTAssertEqual(
          String(decoding: try outputHandle.readToEnd()!, as: UTF8.self),
          output,
          message(),
          file: file, line: line)
        e2.fulfill()
      }
    }
    wait(for: [e1, e2], timeout: 1)
  }
  
  private let supportFilePath = Bundle.module.path(forResource: "Cat", ofType: "txt")!
}
