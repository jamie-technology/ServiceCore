import Dispatch
import notify

/// A Darwin notification (`notify(3)`): delivered to every process of the same
/// user, so an app and its extensions can tell each other something changed.
/// Notifications carry no payload and may be coalesced.
struct DarwinNotification: Sendable {
    let name: String

    func post() {
        notify_post(name)
    }

    /// Yields on every notification until the stream is cancelled.
    func stream() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        var token: Int32 = 0
        let status = notify_register_dispatch(name, &token, DispatchQueue.global()) { _ in
            continuation.yield()
        }
        guard status == NOTIFY_STATUS_OK else {
            continuation.finish()
            return stream
        }
        let registration = token
        continuation.onTermination = { _ in notify_cancel(registration) }
        return stream
    }
}
