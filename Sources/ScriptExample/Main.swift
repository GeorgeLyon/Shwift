
import Shell
import class Foundation.FileManager

import SystemPackage

@main
struct Script {
  static func main() async throws {
    let shell = Shell(
      workingDirectory: .init(FileManager.default.currentDirectoryPath),
      environment: [:],
      standardInput: .nullDevice,
      standardOutput: .standardOutput,
      standardError: .standardError)
    
    #if os(macOS)
    let echo = Executable(path: "/bin/echo")
    let cat = Executable(path: "/bin/cat")
    #elseif os(Linux)
    let echo = Executable(path: "/usr/bin/echo")
    let cat = Executable(path: "/usr/bin/cat")
    #endif
    let sed = Executable(path: "/usr/bin/sed")
    let xxd = Executable(path: "/usr/bin/xxd")
    let head = Executable(path: "/usr/bin/head")

    func printSeparator() {
      let pipe = try! FileDescriptor.pipe()
      defer { 
        try! pipe.readEnd.close()
        try! pipe.writeEnd.close()
      }
      print(String(repeating: "-", count: 40) + "(\(pipe.readEnd.rawValue))")
    }

    for i in 0..<100000 {
      printSeparator()
      do {
        try await shell.execute(echo, arguments: ["\(i):", "Foo", "Bar"])

        printSeparator()

        try await shell.pipe(
          .output,
          of: { shell in
            try await shell.execute(echo, arguments: ["\(i):", "Foo", "Bar"])
          },
          to: { shell in
            try await shell.execute(sed, arguments: ["s/Bar/Baz/"])
          })

        printSeparator()
        
        try await shell.pipe(
          .output,
          of: { shell in
            try await shell.execute(cat, arguments: ["/dev/urandom"])
          },
          to: { shell in
            try await shell.pipe(
              .output,
              of: { shell in
                try await shell.execute(xxd, arguments: [])
              },
              to: { shell in
                try await shell.execute(head, arguments: ["-n2"])
              })
          })

          printSeparator()
      } catch {
        print(error)
      }
    }
  }
}
