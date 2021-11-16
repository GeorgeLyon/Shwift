
@_implementationOnly import NIO
import SystemPackage

extension NIOPipeBootstrap {
  
  /**
   Duplicates the provided file descriptors and creates a channel with the specified input and output. If creating the channel fails, both duplicate descriptors are closed. The caller is responsible for ensuring `inputDescriptor` and `outputDescriptor` are closed.
   */
  func duplicating(
    inputDescriptor: SystemPackage.FileDescriptor,
    outputDescriptor: SystemPackage.FileDescriptor
  ) async throws -> Channel {
    let input = try inputDescriptor.duplicate()
    do {
      let output = try outputDescriptor.duplicate()
      do {
        return try await withPipes(
          inputDescriptor: input.rawValue,
          outputDescriptor: output.rawValue)
          .get()
        /**
         On success, there is no need to close `input` and `output` as they are now owned by the channel
         */
      } catch {
        try! output.close()
        throw error
      }
    } catch {
      try! input.close()
      throw error
    }
  }
  
}
