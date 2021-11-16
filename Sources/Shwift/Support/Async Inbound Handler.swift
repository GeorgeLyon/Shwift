import NIOCore

public final class AsyncInboundHandler<InboundIn>: ChannelInboundHandler, AsyncSequence {
  
  public typealias BufferingPolicy = AsyncStream<Element>.Continuation.BufferingPolicy
  public init(bufferingPolicy: BufferingPolicy = .unbounded) {
    var continuation: AsyncStream<Element>.Continuation!
    stream = AsyncStream(bufferingPolicy: bufferingPolicy) {
      continuation = $0
    }
    self.continuation = continuation
  }
  private func yield(_ event: Element) {
    continuation.yield(event)
  }
  
  public struct AsyncIterator: AsyncIteratorProtocol {
    public mutating func next() async throws -> Element? {
      await wrapped.next()
    }
    fileprivate var wrapped: AsyncStream<Element>.AsyncIterator
  }
  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(wrapped: stream.makeAsyncIterator())
  }
  
  private let stream: AsyncStream<Element>
  private let continuation: AsyncStream<Element>.Continuation
}

// MARK: - Event Forwarding

extension AsyncInboundHandler {
  public enum Element {
    case handlerAdded(ChannelHandlerContext)
    case handlerRemoved(ChannelHandlerContext)
    case channelRead(ChannelHandlerContext, InboundIn)
    case channelReadComplete(ChannelHandlerContext)
    case errorCaught(ChannelHandlerContext, Swift.Error)
    case userInboundEventTriggered(ChannelHandlerContext, Any)
  }
  
  public func handlerAdded(context: ChannelHandlerContext) {
    yield(.handlerAdded(context))
  }
  
  public func handlerRemoved(context: ChannelHandlerContext) {
    yield(.handlerRemoved(context))
  }
  
  public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    yield(.channelRead(context, unwrapInboundIn(data)))
  }
  
  public func channelReadComplete(context: ChannelHandlerContext) {
    yield(.channelReadComplete(context))
  }
  
  public func errorCaught(context: ChannelHandlerContext, error: Swift.Error) {
    yield(.errorCaught(context, error))
  }
  
  public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    yield(.userInboundEventTriggered(context, event))
  }
  
}
