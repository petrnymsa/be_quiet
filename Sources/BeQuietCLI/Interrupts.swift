import Darwin
import Foundation

/// SIGINT/SIGTERM are ignored by the default disposition and observed through
/// dispatch sources instead, so a command can shut down before the process
/// exits and the event loop can drain.
enum Interrupts {
    static func install(_ handler: @escaping @Sendable () -> Void) -> [DispatchSourceSignal] {
        let queue = DispatchQueue(label: "cz.nymsa.BeQuiet.cli.signal")
        return [SIGINT, SIGTERM].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler(handler: handler)
            source.resume()
            return source
        }
    }
}
