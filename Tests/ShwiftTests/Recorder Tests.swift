import XCTest
@testable import Shwift

final class RecorderTests: XCTestCase {

  func testRecorder() async throws {
    let recorder = Shwift.Output.Recorder()
    await recorder.record("Output\n", from: .output)
    await recorder.record("Error\n", from: .error)
    var output = ""
    await recorder.output.write(to: &output)
    var error = ""
    await recorder.error.write(to: &error)
    var joined = ""
    await recorder.write(to: &joined)
    XCTAssertEqual("Output\n", output)
    XCTAssertEqual("Error\n", error)
    XCTAssertEqual("Output\nError\n", joined)
  }

}
