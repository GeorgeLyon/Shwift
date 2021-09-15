
import SystemPackage

extension Shell {
  
  public struct Executable {
    let path: FilePath
  }
  
}

public extension Shell {
  
  func executable(named name: String) throws -> Executable? {
    try environment
      .path(forExecutableNamed: name, strict: false)
      .map(Shell.Executable.init)
  }
  
  func execute(
    _ executable: Shell.Executable,
    arguments: [String?] = []
  ) async throws {
    try await withFileDescriptor(for: input) { input in
      try await withFileDescriptor(for: output) { output in
        try await withFileDescriptor(for: error) { error in
          try await childProcessManager
            .run(
              executablePath: executable.path,
              arguments: arguments.compactMap { $0 },
              workingDirectory: directory.string,
              environmentValues: environment.values,
              input: input,
              output: output,
              error: error)
        }
      }
    }
  }
  
}
