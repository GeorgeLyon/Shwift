
extension Shell {

  public func pipe(_ value: Int) async throws {
    #if os(macOS)
    let echo = Executable(path: "/bin/echo")
    #elseif os(Linux)
    let echo = Executable(path: "/usr/bin/echo")
    #endif
    let sed = Executable(path: "/usr/bin/sed")
    let head = Executable(path: "/usr/bin/head")

    let pipe = try FileDescriptor.pipe()
    
    try await invoke { shell in
      let sourceShell = Shell(
        workingDirectory: shell.workingDirectory,
        environment: shell.environment,
        standardInput: .unmanaged(shell.standardInput),
        standardOutput: .unmanaged(pipe.writeEnd),
        standardError: .unmanaged(shell.standardError),
        nioContext: shell.nioContext)
      let sourceTask = Task {
        try await sourceShell.execute(echo, arguments: ["\(value):", "Foo", "Bar"])
        try pipe.writeEnd.close()
      }
      
      let destinationShell = Shell(
        workingDirectory: shell.workingDirectory,
        environment: shell.environment,
        standardInput: .unmanaged(pipe.readEnd),
        standardOutput: .unmanaged(shell.standardOutput),
        standardError: .unmanaged(shell.standardError),
        nioContext: shell.nioContext)
      let destinationTask = Task {
        try await destinationShell.execute(sed, arguments: ["s/Bar/Baz/"])
        // try await destinationShell.execute(head, arguments: ["-c6"])
        try pipe.readEnd.close()
      }

      try await sourceTask.value
      try await destinationTask.value
      print(String(repeating: "-", count: 40))
    }
  }
}