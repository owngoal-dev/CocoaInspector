import Foundation

// A clock that only moves when told to, so every grace period and minimum
// time can be stepped through exactly, without sleeping.
final class ManualScheduler {
    private struct Pending {
        let id: Int
        let deadline: TimeInterval
        let action: () -> Void
    }

    private(set) var now: TimeInterval = 0
    private var pending: [Pending] = []
    private var nextID = 0

    var schedule: DelayedLoadingIndicator.Schedule {
        { [unowned self] delay, action in
            nextID += 1
            let id = nextID
            pending.append(Pending(id: id, deadline: now + delay, action: action))
            return { [weak self] in self?.pending.removeAll { $0.id == id } }
        }
    }

    var pendingCount: Int { pending.count }

    func advance(by interval: TimeInterval) {
        let end = now + interval
        while let next = pending.filter({ $0.deadline <= end }).min(by: { $0.deadline < $1.deadline }) {
            pending.removeAll { $0.id == next.id }
            now = next.deadline
            next.action()
        }
        now = end
    }
}

@main
enum DelayedLoadingHarness {
    static func main() {
        let grace: TimeInterval = 0.75
        let minimum: TimeInterval = 0.5

        func make() -> (DelayedLoadingIndicator, ManualScheduler, () -> Int) {
            let clock = ManualScheduler()
            let indicator = DelayedLoadingIndicator(
                gracePeriod: grace,
                minimumVisibleTime: minimum,
                schedule: clock.schedule
            )
            var changes = 0
            indicator.onChange = { changes += 1 }
            return (indicator, clock, { changes })
        }

        // Loading that ends inside the grace period never shows anything,
        // and leaves nothing scheduled behind it.
        do {
            let (indicator, clock, changes) = make()
            precondition(!indicator.update(isLoading: true))
            clock.advance(by: grace - 0.1)
            precondition(!indicator.update(isLoading: true))
            precondition(!indicator.update(isLoading: false))
            precondition(clock.pendingCount == 0)
            clock.advance(by: 5)
            precondition(changes() == 0)
            precondition(!indicator.isVisible && !indicator.holdsContent)
        }

        // Reporting loading again doesn't restart the grace period: the
        // indicator is due a grace period after loading began.
        do {
            let (indicator, clock, changes) = make()
            indicator.update(isLoading: true)
            clock.advance(by: grace / 2)
            indicator.update(isLoading: true)
            clock.advance(by: grace / 2)
            precondition(changes() == 1)
            precondition(indicator.update(isLoading: true))
        }

        // Loading that outlasts the grace period shows the indicator, which
        // holds content back for its minimum time and then lets it through.
        do {
            let (indicator, clock, changes) = make()
            indicator.update(isLoading: true)
            clock.advance(by: grace)
            precondition(changes() == 1)
            precondition(indicator.isVisible && indicator.holdsContent)
            clock.advance(by: minimum - 0.1)
            precondition(indicator.holdsContent)
            clock.advance(by: 0.1)
            precondition(changes() == 2)
            precondition(indicator.isVisible && !indicator.holdsContent)
            // Loading that runs on keeps it, without another change.
            clock.advance(by: 10)
            precondition(indicator.update(isLoading: true))
            precondition(changes() == 2)
            precondition(!indicator.update(isLoading: false))
            precondition(clock.pendingCount == 0)
        }

        // A failure doesn't wait: ending the loading while the indicator is
        // still inside its minimum removes it at once, with no late change.
        do {
            let (indicator, clock, changes) = make()
            indicator.update(isLoading: true)
            clock.advance(by: grace + 0.1)
            precondition(indicator.holdsContent)
            precondition(!indicator.update(isLoading: false))
            precondition(!indicator.isVisible && !indicator.holdsContent)
            precondition(clock.pendingCount == 0)
            clock.advance(by: 5)
            precondition(changes() == 1)
        }

        // Trying again after that starts over from a fresh grace period.
        do {
            let (indicator, clock, changes) = make()
            indicator.update(isLoading: true)
            clock.advance(by: grace + minimum)
            indicator.update(isLoading: false)
            precondition(!indicator.update(isLoading: true))
            clock.advance(by: grace - 0.1)
            precondition(!indicator.isVisible)
            clock.advance(by: 0.1)
            precondition(indicator.isVisible && indicator.holdsContent)
            precondition(changes() == 3)
        }

        // An indicator that goes away takes its pending work with it.
        do {
            let clock = ManualScheduler()
            var indicator: DelayedLoadingIndicator? = DelayedLoadingIndicator(
                gracePeriod: grace,
                minimumVisibleTime: minimum,
                schedule: clock.schedule
            )
            indicator?.update(isLoading: true)
            precondition(clock.pendingCount == 1)
            indicator = nil
            precondition(clock.pendingCount == 0)
        }

        print("Inspector delayed-loading harness passed")
    }
}
