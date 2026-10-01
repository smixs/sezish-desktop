import Foundation

/// Which meetings have a summary run going right now. A run can last half an hour per
/// attempt, and the retry button can be pressed meanwhile (or twice): two agents
/// writing the same cards would be worse than a button that does nothing.
nonisolated struct SummaryRunGate {
    private var running: Set<String> = []

    /// - Returns: false when this meeting already has a run, true when the caller owns it.
    mutating func begin(_ md: URL) -> Bool {
        running.insert(md.standardizedFileURL.path).inserted
    }

    mutating func end(_ md: URL) {
        running.remove(md.standardizedFileURL.path)
    }
}
