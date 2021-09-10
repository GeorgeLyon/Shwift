
import SystemPackage

extension Shell {
  
  public struct Executable {
    fileprivate let path: FilePath
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
  ) throws {
    try input.withFileDescriptor { input in
      try output.withFileDescriptor { output in
        try error.withFileDescriptor { error in
          try childProcessManager
            .run(
              executablePath: executable.path,
              arguments: arguments.compactMap { $0 },
              workingDirectory: directory.filePath.string,
              environmentValues: environment.values,
              input: input,
              output: output,
              error: error)
        }
      }
    }
  }
  
}
