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

  /// Demo [#22 dropped remainder](https://github.com/GeorgeLyon/Shwift/issues/22)
  func testEchoMapWithDelimiters() async throws {
    try runInScript {
      let result = try await outputOf {
        try await echo("1", "2", separator: ",", terminator: "")
        | compactMap(segmentingInputAt: ",", withOutputTerminator: "|") { "<\($0)>"}
      }
      let exp = "<1>|<2>|"
      XCTAssertEqual(exp, result, "echo 1,2 -map-> <1>|<2>|")
    }
  }

  /// Verify `reduce` chunks input by splitAt delimiter (and handles non-string output)
  func testReduceChunked() async throws {
    typealias SF = ChunkFixtures
    let result = SF.Result<SF.Ints>() // reference type
    let exp: [SF.Ints] = [.i(1), .pair(2, 3), .i(4), .err("not")]
    try runInScript {
      let sep: Character = ";"

      // inout, here using class
      try await echo("1", "2\n3", "4", "not",
                     separator: "\(sep)", terminator: "")
      | reduce(into: result, segmentingInputAt: sep) { $0.add(.make($1)) }
      XCTAssertEqual(exp, result.result, "Reduce (inside)")

      // returning value each time
      let array: [SF.Ints]
      = try await echo("1", "2\n3", "4", "not",
                       separator: "\(sep)", terminator: "")
      | reduce([], segmentingInputAt: sep) { r, s in r + [SF.Ints.make(s)] }
      XCTAssertEqual(exp, array, "Reduce (arrays)")
    }
    XCTAssertEqual(exp, result.result, "Reduce (outside)")
  }

  /// Verify `map` chunks input by splitAt delimiter
  func testMapChunked() async throws {
    typealias SF = ChunkFixtures
    let mapped: [SF.Ints] = [.i(1), .pair(2, 3), .i(4), .err("not")]
    let expect = mapped.map{ $0.double() }.joined(separator: "\n")
    try runInScript {
      let sep: Character = ";"
      let result = try await outputOf {
        try await echo("1", "2\n3", "4", "not",
                       separator: "\(sep)", terminator: "")
        | map(segmentingInputAt: sep) { SF.Ints.make($0).double() }
      }
      XCTAssertEqual(expect, result, "Map")
    }
  }

  /// Verify `compactMap` chunks input by splitAt delimiter
  func testCompactMapChunked() async throws {
    typealias SF = ChunkFixtures
    let all: [SF.Ints] = [.i(1), .pair(2, 3), .i(4), .err("not")]
    let evens = all.compactMap{ $0.anyEven() }.joined(separator: "\n")
    try runInScript {
      let sep: Character = ";"
      let result = try await outputOf {
        try await echo("1", "2\n3", "4", "not",
                       separator: "\(sep)", terminator: "")
        | compactMap(segmentingInputAt: sep) { SF.Ints.make($0).anyEven() }
      }
      XCTAssertEqual(evens, result, "Map")
    }
  }  /// Run test in Script.run() context
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
  private enum ChunkFixtures {
    class Result<T> {
      var result = [T]()
      func add(_ next: T) {
        result.append(next)
      }
    }
    enum Ints: Codable, Equatable {
      case i(Int), pair(Int, Int), err(String)

      static func make(_ s: String) -> Ints {
        let nums = s.split(separator: "\n")
        switch nums.count {
        case 1:
          if let i = Int(nums[0]) {
            return .i(i)
          }
          return err(s)
        case 2: return .pair(Int(nums[0]) ?? -1, Int(nums[1]) ?? -2)
        default: return .err(s)
        }
      }

      func double() -> String {
        switch self {
        case .i(let n): return "\(2*n)"
        case .pair(let i, let j): return "\(2*i)\n\(2*j)"
        case .err(let s): return "\(s)\(s)"
        }
      }

      func anyEven() -> String? {
        func anyEvens(_ i: Int...) -> Bool {
          nil != i.first { 0 == $0 % 2}
        }
        switch self {
        case .i(let n): return anyEvens(n) ? "\(n)" : nil
        case .pair(let i, let j): return anyEvens(i, j) ? "\(i)\n\(j)" : nil
        case .err: return nil
        }
      }
    }
  }
}

