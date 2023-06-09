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
        try await Process.run(
          "cat", Self.supportFilePath, standardOutput: standardOutput, in: context)
      },
      is: """
        Cat
        """)

    try XCTAssertOutput(
      of: { context, standardOutput in
        try await Process.run("echo", "Echo", standardOutput: standardOutput, in: context)
        try await Process.run(
          "cat", Self.supportFilePath, standardOutput: standardOutput, in: context)
      },
      is: """
        Echo
        Cat
        """)
  }

  func testFailure() throws {
    try XCTAssertOutput(
      of: { context, _ in
        try await Process.run("false", in: context)
      },
      is: .failure)
  }

  func testExecutablePipe() throws {
    try XCTAssertOutput(
      of: { context, output in
        try await Builtin.pipe(
          { output in
            try await Process.run("echo", "Foo", standardOutput: output, in: context)
          },
          to: { input in
            try await Process.run(
              "sed", "s/Foo/Bar/", standardInput: input, standardOutput: output, in: context)
          }
        ).destination
      },
      is: """
        Bar
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

  private enum Outcome: ExpressibleByStringInterpolation {
    init(stringLiteral value: String) {
      self = .success(value)
    }
    case success(String)
    case failure
  }

  private func XCTAssertOutput(
    of operation: @escaping (Context, FileDescriptor) async throws -> Void,
    is expectedOutcome: Outcome,
    file: StaticString = #file, line: UInt = #line,
    function: StaticString = #function
  ) throws {
    let e1 = expectation(description: "\(function):\(line)")
    let e2 = expectation(description: "\(function):\(line)")
    let context = Context()
    Task {
      do {
        let output: String = try await Builtin.pipe(
          { output in
            defer { e1.fulfill() }
            try await operation(context, output)
          },
          to: { input in
            defer { e2.fulfill() }
            do {
              return try await Output.nullDevice.withFileDescriptor(in: context) { output in
                try await Builtin.withChannel(input: input, output: output, in: context) {
                  channel in
                  return try await channel.input.lines
                    .reduce(into: [], { $0.append($1) })
                    .joined(separator: "\n")
                }
              }
            } catch {
              XCTFail(file: file, line: line)
              throw error
            }
          }
        )
        .destination
        switch expectedOutcome {
        case .success(let expected):
          XCTAssertEqual(
            output,
            expected,
            file: file, line: line)
        case .failure:
          XCTFail("Succeeded when expecting failure", file: file, line: line)
        }
      } catch {
        switch expectedOutcome {
        case .success:
          throw error
        case .failure:
          /// Failure was expected
          break
        }
      }

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
