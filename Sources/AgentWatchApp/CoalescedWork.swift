import Foundation

/// Work asked for many times in a row and done once, on the next turn of the main run loop.
///
/// A dragged colour wheel reports a new colour many times before the run loop turns, and each
/// report used to rebuild the whole widget at once. Measured on a copy with 19 sessions: 120
/// theme changes in one turn took the process from 92 MB to 373 MB, and it still held 144 MB
/// three seconds later (`docs/measurements.md`). Done once per turn, the rows are built once.
@MainActor
final class CoalescedWork {
    private let work: () -> Void
    private(set) var isPending = false

    init(_ work: @escaping () -> Void) {
        self.work = work
    }

    func request() {
        guard !isPending else {
            return
        }
        isPending = true
        // The main queue is served in the run loop's common modes, so this runs while a menu
        // or a colour panel is tracking the mouse too, not only after it lets go.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.run()
            }
        }
    }

    /// Does the pending work now, for a caller that cannot wait for the next turn.
    func runIfPending() {
        guard isPending else {
            return
        }
        run()
    }

    private func run() {
        guard isPending else {
            return
        }
        isPending = false
        // Its own pool, so what one rebuild leaves behind is freed before the next begins.
        autoreleasepool {
            work()
        }
    }
}
