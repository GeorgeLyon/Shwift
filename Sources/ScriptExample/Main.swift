
import Foundation
import Script

@main struct Main: Script {
  
  enum Test: EnumerableFlag {
    case echoToSed
    case echoToMap
    case countLines
    case infiniteInput
    case stressTest
  }
  @Flag var tests: [Test] = [.echoToSed, .echoToMap, .countLines]
  
  func run() async throws {
    /**
     Declare the executables first so that we fail fast if one is missing.
     
     We could also instead use the `execute("executable", ...)` form to resolve executables at invocation time
     */
    let echo = try await executable(named: "echo")
    let sed = try await executable(named: "sed")
    let cat = try await executable(named: "cat")
    let head = try await executable(named: "head")
    let xxd = try await executable(named: "xxd")
    
    for test in tests {
      switch test {
      case .echoToSed:
        /// Piping between two executables
        try await echo("Foo", "Bar") | sed("s/Bar/Baz/")
      case .echoToMap:
        /// Piping to a builtin
        try await echo("Foo", "Bar") | map { $0.replacingOccurrences(of: "Bar", with: "Baz") }
      case .countLines:
        /// Getting a Swift value from an invocation
        let numberOfLines = try await echo("Foo", "Bar") | reduce(into: 0, { count, _ in count += 1 })
        print(numberOfLines)
      case .infiniteInput:
        /// Dealing with infinite input (error is ignored because `head` throws `EPIPE`)
        try? await cat("/dev/urandom") | xxd() | map { line in
          "PREFIX: \(line)"
        } | head("-n2")
        /// Sleep so we can validate memory usage doesn't grow as a result of `cat /dev/urandom`
        try await Task.sleep(nanoseconds: 10_000_000_000)
        
      case .stressTest:
        for i in 0..<50_000 {
          try await withThrowingTaskGroup(of: Void.self) { group in
            for j in 0..<50 {
              group.addTask {
                try await echo("\(i),\(j):", "Foo", "Bar") | sed("s/Bar/Baz/")
              }
            }
            for try await _ in group { }
          }
        }
      }
    }
  }
}
