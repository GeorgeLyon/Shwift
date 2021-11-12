
import Script
import SystemPackage

@main struct Main: Script {
  func run() async throws {
    let echo = try await executable(named: "echo")
    let sed = try await executable(named: "sed")
    let cat = try await executable(named: "cat")
    let head = try await executable(named: "head")
    let xxd = try await executable(named: "xxd")
    
    /// Piping between two executables
    try await echo("Foo", "Bar") | sed("s/Bar/Baz/")
    
    /// Piping to a builtin
    try await echo("Foo", "Bar") | map { $0.replacingOccurrences(of: "Bar", with: "Baz") }
    
    /// Creating a new builtin
    let numberOfWords = try await echo("Foo", "Bar") | builtin { handle -> Int in
      var numberOfWords = 0
      for try await line in handle.input.lines {
        numberOfWords += line.components(separatedBy: .whitespaces).count
      }
      return numberOfWords
    }
    print(numberOfWords)
    
    /// Dealing with infinite input (error is ignored because `head` throws `EPIPE`)
    try? await cat("/dev/urandom") | xxd() | map { line in
      "PREFIX: \(line)"
    } | head("-n2")
    
    /// Sleep so we can validate memory usage doesn't grow as a result of `cat /dev/urandom`
    try await Task.sleep(nanoseconds: 10_000_000_000)
  }
}

func stressTest() async throws {
  let echo = try await executable(named: "echo")
  let sed = try await executable(named: "sed")
  for i in 0..<50_000 {
    try await withThrowingTaskGroup(of: Void.self) { group in
      for j in 0..<50 {
        group.addTask {
          try await echo("\(i),\(j):", "Foo", "Bar") | sed("s/Bar/Baz/")
        }
      }
      for try await _ in group {
        
      }
    }
  }
}
