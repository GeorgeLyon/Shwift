
import Script

@main struct Main: Script {
  func run() async throws {
    let echo = try await executable(named: "echo")
    let sed = try await executable(named: "sed")
    
    for i in 0..<1_000 {
      try await withThrowingTaskGroup(of: Void.self) { group in
        for j in 0..<50 {
          group.addTask {
            try await echo("\(i),\(j):", "Foo", "Bar") | sed("s/Bar/Baz/")
            
            try await echo("\(i),\(j):", "Foo", "Bar") | map { $0.replacingOccurrences(of: "Bar", with: "Baz") }
            
            let output = try await outputOf {
              try await echo("\(i),\(j):", "Foo", "Baz")
            }
            print(output)
          }
        }
        for try await _ in group {
          
        }
      }
    }
  }
}
