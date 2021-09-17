
import ArgumentParser
import Script

@main
struct Sample: Script {
  func run() async throws {
    let cat = try executable(named: "cat")
    let echo = try executable(named: "echo")
    let sed = try executable(named: "sed")
    
    print(try await echo("Foo") | sed(#"s/\(.*\)/\1\n\1/"#) | cat() | collect())
    
    print(try await echo("Foo") | map { "\($0)\n\($0)" } | collect())
  }
}
