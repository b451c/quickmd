import Foundation

/// "This stays linear" / "this does not depend on the input's size", checked
/// in a way a loaded machine cannot fail.
///
/// Why not a wall-clock bound (`XCTAssertLessThan(elapsed, 1.0)`): the owner's
/// rule is that no test asserts on machine speed. Several agents running the
/// suite at a load average of ~30 saw such bounds fail while the code was
/// fine — the thread simply waited for a core. Two things make this check
/// independent of the machine:
/// - it measures the CPU time of the CALLING THREAD
///   (`CLOCK_THREAD_CPUTIME_ID`), which does not grow while the thread waits
///   to be scheduled;
/// - it compares the cost at `n` with the cost at `factor × n` — a RATIO, so a
///   slow machine (or a Debug build) is slow on both sides and cancels out.
///
/// With the default factor 8, linear work costs ~8× and quadratic work ~64×;
/// work independent of the size costs ~1× and linear work ~8×. The callers'
/// limits sit between the two, with room for cache effects on the larger
/// input. Each side is the best of several runs, the small side is repeated
/// until it costs a measurable amount, and a failing comparison is retried
/// before it is reported, so one unlucky run (a page fault storm, a frequency
/// change) cannot fail the test.
enum CostScaling {

    struct Result: CustomStringConvertible {
        let small: Int
        let large: Int
        /// CPU seconds of one run at `small` / `large`.
        let smallCost: Double
        let largeCost: Double
        var ratio: Double { largeCost / max(smallCost, 1e-9) }

        var description: String {
            String(format: "n = %d: %.3f ms, n = %d: %.3f ms, ratio %.2f",
                   small, smallCost * 1000, large, largeCost * 1000, ratio)
        }
    }

    /// CPU time the calling thread has used, in seconds.
    static func threadCPUSeconds() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1_000_000_000
    }

    /// CPU seconds `body` costs on this thread.
    static func cpuCost(_ body: () -> Void) -> Double {
        let start = threadCPUSeconds()
        body()
        return threadCPUSeconds() - start
    }

    /// Compares one run of the work at `small` with one at `small × factor`.
    /// `prepare(n)` builds the input of size `n` (not measured) and returns
    /// the work to measure, which must be repeatable. Returns the first
    /// attempt whose ratio is within `limit`, else the best attempt — the
    /// caller asserts on `ratio`. Runs on the calling thread and measures it:
    /// call it on the thread that does the work.
    static func compare(small: Int, factor: Int = 8, limit: Double, attempts: Int = 3,
                        _ prepare: (Int) -> () -> Void) -> Result {
        let smallWork = prepare(small)
        let largeWork = prepare(small * factor)
        smallWork()   // first use: font, regex and allocator warm-up is not the scan
        largeWork()

        // Repeat the small side until it costs ≥ 20 ms, so the ratio is not
        // the quotient of two timer ticks (work of a microsecond: 2^15 runs).
        var repeats = 1
        while repeats < 1 << 15, cpuCost({ for _ in 0..<repeats { smallWork() } }) < 0.02 {
            repeats *= 2
        }

        func perRun(_ work: () -> Void) -> Double {
            var best = Double.infinity
            for _ in 0..<3 {
                best = min(best, cpuCost { for _ in 0..<repeats { work() } } / Double(repeats))
            }
            return best
        }

        var best: Result?
        for _ in 0..<max(1, attempts) {
            let result = Result(small: small, large: small * factor,
                                smallCost: perRun(smallWork), largeCost: perRun(largeWork))
            if result.ratio <= limit { return result }
            if best == nil || result.ratio < best!.ratio { best = result }
        }
        return best!
    }
}
