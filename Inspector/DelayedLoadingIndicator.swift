import Foundation

// Decides when a loading indicator is worth showing. Loading that finishes
// within the grace period shows nothing at all, so a fast connection doesn't
// flash a spinner for a few frames; loading that runs longer shows the
// indicator, which then stays for a minimum time so it doesn't blink off.
//
// It only keeps time. The owner reports whether it is loading on every render
// and draws what `update(isLoading:)` answers; `onChange` asks it to render
// again when the answer changes on its own. Main thread only. Foundation only,
// so `make harness` can drive it on macOS with a scheduler of its own.
final class DelayedLoadingIndicator {
    /// Runs `action` after `delay` seconds, and returns a way to cancel it.
    typealias Schedule = (_ delay: TimeInterval, _ action: @escaping () -> Void) -> () -> Void

    private enum Stage {
        case idle
        // Loading, and the indicator is not due yet.
        case waiting
        // The indicator is up, and has not been for its minimum time.
        case showing
        // The indicator is up, and may go whenever the loading ends.
        case settled
    }

    static let defaultGracePeriod: TimeInterval = 0.75
    static let defaultMinimumVisibleTime: TimeInterval = 0.5

    /// Called when the indicator appears, and when its minimum time is over.
    var onChange: () -> Void = {}

    private let gracePeriod: TimeInterval
    private let minimumVisibleTime: TimeInterval
    private let schedule: Schedule
    private var stage = Stage.idle
    private var cancelPending: (() -> Void)?

    init(
        gracePeriod: TimeInterval = defaultGracePeriod,
        minimumVisibleTime: TimeInterval = defaultMinimumVisibleTime,
        schedule: @escaping Schedule = DelayedLoadingIndicator.onMainQueue
    ) {
        self.gracePeriod = gracePeriod
        self.minimumVisibleTime = minimumVisibleTime
        self.schedule = schedule
    }

    deinit {
        cancelPending?()
    }

    /// Whether the indicator is on screen.
    var isVisible: Bool {
        stage == .showing || stage == .settled
    }

    /// The indicator has only just appeared. Content that is ready waits for
    /// the next `onChange` rather than replacing it at once; a message such
    /// as a failure need not wait, and ends it with `update(isLoading: false)`.
    var holdsContent: Bool {
        stage == .showing
    }

    /// Reports whether the screen is loading, and answers whether the
    /// indicator belongs on it. Loading that ends ends the indicator at once.
    @discardableResult
    func update(isLoading: Bool) -> Bool {
        if !isLoading {
            cancel()
        } else if stage == .idle {
            stage = .waiting
            after(gracePeriod) { [weak self] in self?.reveal() }
        }
        return isVisible
    }

    private func reveal() {
        guard stage == .waiting else { return }
        stage = .showing
        after(minimumVisibleTime) { [weak self] in self?.settle() }
        onChange()
    }

    private func settle() {
        guard stage == .showing else { return }
        stage = .settled
        cancelPending = nil
        onChange()
    }

    private func after(_ delay: TimeInterval, _ action: @escaping () -> Void) {
        cancelPending?()
        cancelPending = schedule(delay, action)
    }

    private func cancel() {
        cancelPending?()
        cancelPending = nil
        stage = .idle
    }

    // A dispatch deadline, unlike a default-mode timer, still fires while a
    // scroll view is tracking a finger.
    static let onMainQueue: Schedule = { delay, action in
        let work = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return work.cancel
    }
}
