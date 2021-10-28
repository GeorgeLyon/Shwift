
import Shell
import class Foundation.FileManager

import Foundation
import SystemPackage
import NIO
import _NIOConcurrency

// @main
// struct Script {
//  static func main() async throws {
//    let pipe = try FileDescriptor.pipe()
//    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

//    final class Handler: ChannelInboundHandler {
//      typealias InboundIn = ByteBuffer
//    }
//    let channel = try await NIOPipeBootstrap(group: group)
//     .channelInitializer { channel in
//       channel.pipeline.addHandler(Handler())
//     }
//     .withPipes(
//       inputDescriptor: pipe.writeEnd.rawValue, 
//       outputDescriptor: pipe.readEnd.rawValue)
//     .get()

//     DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(1)) {
//       print("\(#fileID):\(#line)")
//       try! pipe.readEnd.close()
//       print("\(#fileID):\(#line)")
//     }
    
//     print("\(#fileID):\(#line)")
//     try await channel.closeFuture.get()
//     print("\(#fileID):\(#line)")
//  }
// }

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
    #elseif os(Linux)
    let echo = Executable(path: "/usr/bin/echo")
    #endif

    for i in 0..<100 {
      try await shell.execute(echo, arguments: ["\(i):", "Foo", "Bar"])
    }
  }
}
