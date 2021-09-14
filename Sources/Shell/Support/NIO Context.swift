import NIO

final class NIOContext: Sendable {
  
  private init() {
    eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    threadPool = NIOThreadPool(numberOfThreads: 1)
    nonBlockingFileIO = NonBlockingFileIO(threadPool: threadPool)
  }
  
  deinit {
    var errors: [Error] = []
    do {
      try eventLoopGroup.syncShutdownGracefully()
    } catch {
      errors.append(error)
    }
    do {
      try threadPool.syncShutdownGracefully()
    } catch {
      errors.append(error)
    }
    if !errors.isEmpty {
      Task { [errors] in
        await Self.shared.report(errors)
      }
    }
  }
  
  private let threadPool: NIOThreadPool
  private let eventLoopGroup: EventLoopGroup
  private let nonBlockingFileIO: NonBlockingFileIO
  
  private actor Shared {
    var context: NIOContext {
      if let context = _context {
        return context
      } else {
        let context = NIOContext()
        _context = context
        return context
      }
    }
    
    fileprivate func report(_ errors: [Error]) {
      assertionFailure()
      _errors.append(contentsOf: errors)
    }
    
    private weak var _context: NIOContext?
    private var _errors: [Error] = []
  }
  private static let shared = Shared()
}
