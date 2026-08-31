import Foundation

/// ASCII-safe base names for meeting artifacts (`call-2026-07-25-14-32`):
/// vault folders sync to other OSes and clouds, so no locale in file names.
public enum MeetingFileNamer {
    public static func baseName(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "call-%04d-%02d-%02d-%02d-%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0
        )
    }

    /// The inverse of `baseName(for:)`, down to the minute it names; a "-2"
    /// collision suffix is allowed and names the same minute. nil for anything
    /// this type did not write, so the caller can fall back to the file's own
    /// dates instead of inventing one.
    public static func date(fromBaseName name: String, calendar: Calendar = .current) -> Date? {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 6 || parts.count == 7, parts[0] == "call" else { return nil }
        guard parts.dropFirst().allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
            return nil
        }
        let fields = parts[1..<6].compactMap { Int($0) }
        // Ranges, not just digits: a calendar happily rolls month 99 forward into
        // some other year, and a name we never wrote must not name a date.
        guard fields.count == 5,
              (1...12).contains(fields[1]),
              (1...31).contains(fields[2]),
              (0...23).contains(fields[3]),
              (0...59).contains(fields[4])
        else { return nil }
        return calendar.date(from: DateComponents(
            year: fields[0], month: fields[1], day: fields[2],
            hour: fields[3], minute: fields[4]
        ))
    }

    /// Appends "-2", "-3"… while `existing` says the name is taken.
    public static func uniqueBaseName(
        for date: Date,
        calendar: Calendar = .current,
        existing: (String) -> Bool
    ) -> String {
        let base = baseName(for: date, calendar: calendar)
        guard existing(base) else { return base }
        var suffix = 2
        while existing("\(base)-\(suffix)") { suffix += 1 }
        return "\(base)-\(suffix)"
    }
}
