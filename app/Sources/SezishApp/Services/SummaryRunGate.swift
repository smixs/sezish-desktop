import Foundation

nonisolated struct SummaryRunGate {
    mutating func begin(_ md: URL) -> Bool { true }
    mutating func end(_ md: URL) {}
}
