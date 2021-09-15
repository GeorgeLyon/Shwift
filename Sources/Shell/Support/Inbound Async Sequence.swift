import NIO

public final class InboundAsyncSequence<InboundIn>: ChannelInboundHandler, AsyncSequence {

  public enum Event {
    case read(InboundIn)
    case isActive(Bool)
    case error(Swift.Error)
  }
  
  public typealias Element = [Event]
  
  public struct AsyncIterator: AsyncIteratorProtocol {
    public mutating func next() async throws -> Element? {
      guard let next = try await sequence?.nextEvents else {
        self = AsyncIterator(sequence: nil)
        return nil
      }
      return next
    }
    fileprivate let sequence: InboundAsyncSequence?
  }
  public func makeAsyncIterator() -> AsyncIterator {
    AsyncIterator(sequence: self)
  }

  public func handlerAdded(context: ChannelHandlerContext) {
    precondition(continuation == nil)
    /// We expect `autoRead` to be `false`, so we need a context on which to first call `read`
    self.context = context
  }

  public func handlerRemoved(context: ChannelHandlerContext) {
    /// No one should be awaitng on this handler when it is removed
    precondition(continuation == nil)
    self.context = nil
  }

  public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    enqueue(.read(unwrapInboundIn(data)))
    context.fireChannelRead(data)
  }

  public func channelReadComplete(context: ChannelHandlerContext) {
    context.fireChannelReadComplete()
    flushEvents()
  }
  
  public func errorCaught(context: ChannelHandlerContext, error: Swift.Error) {
    enqueue(.error(error))
    flushEvents()
    context.fireErrorCaught(error)
  }

  public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
    defer { context.fireUserInboundEventTriggered(event) }
    if case .inputClosed = event as? ChannelEvent {
      switch state {
      case .idle:
        state = .inputClosed(remainder: nil)
      case .buffered(let events):
        state = .inputClosed(remainder: events)
      case .inputClosed:
        preconditionFailure()
      }
    }
  }
  
  public func channelActive(context: ChannelHandlerContext) {
    enqueue(.isActive(true))
    context.fireChannelActive()
    flushEvents()
  }

  public func channelInactive(context: ChannelHandlerContext) {
    if case .inputClosed = state { return }
    enqueue(.isActive(false))
    context.fireChannelInactive()
    flushEvents()
  }

  private func enqueue(_ event: Event) {
    switch state {
    case .idle:
      state = .buffered([event])
    case .buffered(var events):
      events.append(event)
      state = .buffered(events)
    case .inputClosed:
      preconditionFailure()
    }
  }

  private func flushEvents() {
    guard let continuation = continuation else {
      return
    }

    let result: [Event]?
    switch state {
    case .idle:
      result = []
    case .buffered(let events):
      state = .idle
      result = events
    case .inputClosed(let remainder?):
      state = .inputClosed(remainder: nil)
      result = remainder
    case .inputClosed:
      assertionFailure()
      return
    }
    
    self.continuation = nil
    continuation.resume(returning: result)
  }

  private var nextEvents: [Event]? {
    get async throws {
      try await withCheckedThrowingContinuation { continuation in
        context.eventLoop.execute { [self] in
          
          switch self.continuation {
          case let oldValue?:
            assertionFailure()
            oldValue.resume(throwing: Error.multipleConcurrentListeners)
            continuation.resume(throwing: Error.multipleConcurrentListeners)
          case nil:
            break
          }

          switch state {
          case .idle:
            self.continuation = continuation
            /// We expect to only await on handlers that are part of a `ChannelPipeline`
            context.read()
          case .buffered(let events):
            state = .idle
            continuation.resume(returning: events)
          case .inputClosed(let remainder):
            state = .inputClosed(remainder: nil)
            continuation.resume(returning: remainder)
            
          }
        }
      }
    }
  }

  private enum Error: Swift.Error {
    case multipleConcurrentListeners
  }

  private enum State {
    case idle
    case buffered([Event])
    case inputClosed(remainder: [Event]?)
  }
  private var state: State = .idle
  private var context: ChannelHandlerContext!
  private var continuation: CheckedContinuation<[Event]?, Swift.Error>?
}
