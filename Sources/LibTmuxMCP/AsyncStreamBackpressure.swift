import Foundation

package enum AsyncStreamBackpressure {
    package static func enqueue<Element: Sendable>(
        _ element: Element,
        to continuation: AsyncStream<Element>.Continuation
    ) -> Bool {
        while true {
            switch continuation.yield(element) {
            case .enqueued: return true
            case .dropped: Thread.sleep(forTimeInterval: 0.001)
            case .terminated: return false
            @unknown default: return false
            }
        }
    }
}
