import Foundation

public final class ProcessSignalMonitor {
    private let sources: [DispatchSourceSignal]

    public init(signals: [Int32] = [SIGINT, SIGTERM], handler: @escaping () -> Void) {
        self.sources = signals.map { signalNumber in
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler(handler: handler)
            source.resume()
            return source
        }
    }

    deinit {
        sources.forEach { $0.cancel() }
    }
}
