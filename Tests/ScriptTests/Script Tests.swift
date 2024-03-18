import XCTest
import Script

final class ScriptCoreTests: XCTestCase {

  func testEcho() async throws {
    try runInScript {
      var result: String
      result = try await outputOf {
        try await echo("1", "2")
      }
      // fyi, trailing newline stripped by outputOf
      XCTAssertEqual("1 2", result, "echo 1 2")

      result = try await outputOf {
        try await echo("1", "2", separator: ",", terminator: ";")
      }
      XCTAssertEqual("1,2;", result, "echo 1,2;")
    }
  }

  func testEchoMap() async throws {
    try runInScript {
      var result: String
      result = try await outputOf {
        // inject newline so map op runs on head then tail
        try await echo("1", "2", "\n", "3", "4") | map(){"<\($0)>"}
      }
      XCTAssertEqual("<1 2 >\n< 3 4>", result, "echo 1 2 \n 3 4 | map{<$0>}")
    }
  }

  /// Run test in Script.run() context
  private func runInScript(
    _ op: @escaping RunInScriptProxy.Op,
    caller: StaticString = #function,
    callerLine: UInt = #line
  ) throws {
    let e = expectation(description: "\(caller):\(callerLine)")
    try RunInScriptProxy(op, e).run() // sync call preferred
    wait(for: [e], timeout: 2)
  }

  private struct RunInScriptProxy: Script {
    typealias Op = () async throws -> Void
    var op: Op?
    var e: XCTestExpectation?
    init(_ op: @escaping Op, _ e: XCTestExpectation) {
      self.op = op
      self.e = e
    }
    func run() async throws {
      defer { e?.fulfill() }
      try await op?()
    }
    // Codable
    init() {}
    var i = 0
    private enum CodingKeys: String, CodingKey {
      case i
    }
  }
}

