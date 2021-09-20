
import ArgumentParser
import Script

@main
struct Sample: Script {
  func run() async throws {
    let cat = try await executable(named: "cat")
    let echo = try await executable(named: "echo")
    let sed = try await executable(named: "sed")
    
    print(try await echo("Foo") | sed(#"s/\(.*\)/\1\n\1/"#) | cat() | capture())
    
    print(try await echo("Foo") | map { "\($0)\n\($0)" } | capture())
  }
}
