
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
    

    try await invoke { invocation in

      let sourceShell = Shell(
        workingDirectory: workingDirectory,
        environment: environment,
        standardInput: .unmanaged(invocation.standardInput),
        standardOutput: .unmanaged(pipe.writeEnd),
        standardError: .unmanaged(invocation.standardError),
        nioContext: nioContext)
      let sourceTask = Task {
        try await sourceShell.execute(echo, arguments: ["\(value):", "Foo", "Bar"])
        try pipe.writeEnd.close()
      }
      
      let destinationShell = Shell(
        workingDirectory: workingDirectory,
        environment: environment,
        standardInput: .unmanaged(pipe.readEnd),
        standardOutput: .unmanaged(invocation.standardOutput),
        standardError: .unmanaged(invocation.standardError),
        nioContext: nioContext)
      let destinationTask = Task {
        try await destinationShell.execute(sed, arguments: ["s/Bar/Baz/"])
        // try await destinationShell.execute(head, arguments: ["-c6"])
        try pipe.readEnd.close()
      }

      try await sourceTask.value
      try await destinationTask.value
      try await FileDescriptor.withPipe { print(String(repeating: "-", count: 40) + "\($0.readEnd.rawValue)") }
    }
  }
}