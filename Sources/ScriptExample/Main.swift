
import Script

@main struct Main: Script {
  func run() async throws {
    let echo = try await executable(named: "echo")
    let sed = try await executable(named: "sed")
    
    try await echo("Foo", "Bar") | sed("s/Bar/Baz/")
    
    try await echo("Foo", "Bar") | map { $0.replacingOccurrences(of: "Bar", with: "Baz") }
    
    let output = try await outputOf {
      try await echo("Foo", "Bar")
    }
    print(output)
  }
}
