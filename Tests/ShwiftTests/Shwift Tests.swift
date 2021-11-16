import XCTest
import SystemPackage
@testable import Shwift

final class ShwiftCoreTests: XCTestCase {

  func testExecutable() throws {
    try XCTAssertOutput(
      of: { context, standardOutput in
        try await Process.run("echo", "Echo", standardOutput: standardOutput, in: context)
      },
      is: """
        Echo
        """)
    
    try XCTAssertOutput(
      of: { context, standardOutput in
        try await Process.run("cat", Self.supportFilePath, standardOutput: standardOutput, in: context)
      },
      is: """
      Cat
      """)

    try XCTAssertOutput(
      of: { context, standardOutput in
        try await Process.run("echo", "Echo", standardOutput: standardOutput, in: context)
        try await Process.run("cat", Self.supportFilePath, standardOutput: standardOutput, in: context)
      },
      is: """
      Echo
      Cat
      """)
  }
  
  func textExecutablePipe() throws {
    try XCTAssertOutput(
      of: { context, output in
        try await Builtin.pipe(
          { output in
            try await Process.run("echo", "Input", standardOutput: output, in: context)
          },
          to: { input in
            try await Process.run("sed", "s/Input/Output/", standardInput: input, standardOutput: output, in: context)
          }).destination
      },
      is: """
      Echo
      Cat
      """)
  }
  
  func testBuiltinOutput() throws {
    try XCTAssertOutput(
      of: { context, output in
        try await Input.nullDevice.withFileDescriptor(in: context) { input in
          try await Builtin.withChannel(input: input, output: output, in: context) { channel in
            try await channel.output.withTextOutputStream { stream in
              print("Builtin \("(interpolated)")", to: &stream)
            }
          }
        }
      },
      is: """
      Builtin (interpolated)
      """)
  }

  func testReadFromFile() throws {
    try XCTAssertOutput(
      of: { context, output in
        try await Builtin.read(from: FilePath(Self.supportFilePath), to: output, in: context)
      },
      is: """
        Cat
        """)
  }
  
  private func XCTAssertOutput(
    of operation: @escaping (Context, FileDescriptor) async throws -> Void,
    is expected: String?,
    file: StaticString = #file, line: UInt = #line,
    function: StaticString = #function
  ) throws {
    let e1 = expectation(description: "\(function):\(line)")
    let e2 = expectation(description: "\(function):\(line)")
    let context = Context()
    Task {
      try await Builtin.pipe(
        { output in
          defer { e1.fulfill() }
          try await operation(context, output)
        },
        to: { input in
          defer { e2.fulfill() }
          do {
            try await Output.nullDevice.withFileDescriptor(in: context) { output in
              try await Builtin.withChannel(input: input, output: output, in: context) { channel in
                let lines: [String] = try await  channel.input.lines
                  .reduce(into: [], { $0.append($1) })
                XCTAssertEqual(
                  lines.joined(separator: "\n"),
                  expected,
                  file: file, line: line)
              }
            }
          } catch {
            XCTFail(file: file, line: line)
          }
        })
    }
    wait(for: [e1, e2], timeout: 2)
  }
  
  private static let supportFilePath = Bundle.module.path(forResource: "Cat", ofType: "txt")!
}

private extension Shwift.Process {
  static let environment: Environment = .process
  static func run(
    _ executableName: String,
    _ arguments: String...,
    standardInput: FileDescriptor? = nil,
    standardOutput: FileDescriptor? = nil,
    in context: Context
  ) async throws {
    var fileDescriptors = FileDescriptorMapping()
    if let standardInput = standardInput {
      fileDescriptors.addMapping(from: standardInput, to: STDIN_FILENO)
    }
    if let standardOutput = standardOutput {
      fileDescriptors.addMapping(from: standardOutput, to: STDOUT_FILENO)
    }
    try await run(
      executablePath: environment.searchForExecutables(named: executableName).matches.first!,
      arguments: arguments,
      environment: [:],
      workingDirectory: FilePath(FileManager.default.currentDirectoryPath),
      fileDescriptors: fileDescriptors,
      in: context)
  }
}
