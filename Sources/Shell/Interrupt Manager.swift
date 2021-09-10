import Foundation

protocol InterruptHandler: AnyObject, Sendable {
  /**
   Called if the process receives a `SIGINT` while this handler is registered with the shared interrupt manager.

   This method is called on `manager.queue`
   */
  func handleInterrupt() async
}

final class InterruptManager: @unchecked Sendable {

  init() {
    source = DispatchSource.makeSignalSource(signal: SIGINT, queue: Self.queue)
    source.setEventHandler { [weak self] in
      guard let self = self else { return }
      let sem = DispatchSemaphore(value: 0)
      let entries = self.entries
      self.entries.removeAll()
      Task {
        await withTaskGroup(of: Void.self) { group in
          entries.values.forEach { entry in
            group.addTask {
              await entry.handler?.handleInterrupt()
            }
          }
        }
        sem.signal()
      }
      sem.wait()
      exit(SIGINT)
    }
    source.resume()

    dispatchPrecondition(condition: .onQueue(queue))
    signal(SIGINT, SIG_IGN)
  }

  deinit {
    source.cancel()
    queue.sync {
      precondition(entries.isEmpty)
      signal(SIGINT, SIG_DFL)
    }
  }

  /**
   Registers an interrupt handler, keeping a `weak` reference to this handler.

   If the process receives a `SIGINT` while this handler is registered, the handlers `handleInterrupt` method will be called.

   - warning: The caller is responsible for ensuring `unregister(handler)` is called before `handler`'s `deinit` returns.
   */
  func register<T: InterruptHandler>(_ handler: T) {
    let entry = Entry(handler: handler)
    let id = ObjectIdentifier(handler)
    queue.sync {
      precondition(!entries.keys.contains(id))
      entries[id] = entry
    }
  }

  /**
   Unregisters an interrupt handler. This method is safe to call from `handler`'s `deinit`.
   */
  func unregister<T: InterruptHandler>(_ handler: T) {
    let id = ObjectIdentifier(handler)
    queue.sync {
      let removed = entries.removeValue(forKey: id)
      precondition(removed != nil)
    }
  }

  var queue: DispatchQueue { Self.queue }
  
  static var shared: InterruptManager {
    queue.sync {
      if let shared = _shared {
        return shared
      } else {
        let shared = InterruptManager()
        _shared = shared
        return shared
      }
    }
  }
  
  private struct Entry: Sendable {
    weak var handler: InterruptHandler?
  }
  private var entries: [ObjectIdentifier: Entry] = [:]

  private let source: DispatchSourceSignal

  private static weak var _shared: InterruptManager?
  private static let queue = DispatchQueue(label: #fileID)
}
