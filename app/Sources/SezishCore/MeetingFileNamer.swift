import Foundation

/// ASCII-safe base names for meeting artifacts (`call-2026-07-25-14-32`):
/// vault folders sync to other OSes and clouds, so no locale in file names.
/// With a known call app the slug of its display name joins the minute
/// (`call-2026-09-16-08-32-telegram`), so the folder shows where the call was.
public enum MeetingFileNamer {
    private static let maxSlugLength = 16

    /// `Telegram` → `telegram`, `zoom.us` → `zoomus`, `Google Chrome` →
    /// `googlechrome`. Anything else falls out; an empty or digits-only result
    /// is nil, so the name stays slugless exactly like a meeting with no app.
    /// A digits-only slug would read as a `-2` collision suffix, which is why
    /// it is refused.
    public static func appSlug(from displayName: String) -> String? {
        let slug = String(displayName.lowercased().filter {
            $0.isASCII && ($0.isLetter || $0.isNumber)
        }.prefix(maxSlugLength))
        guard slug.contains(where: { $0.isLetter }) else { return nil }
        return slug
    }

    public static func baseName(
        for date: Date, app: String? = nil, calendar: Calendar = .current
    ) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let dated = String(
            format: "call-%04d-%02d-%02d-%02d-%02d",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0
        )
        guard let app, let slug = appSlug(from: app) else { return dated }
        return "\(dated)-\(slug)"
    }

    /// The inverse of `baseName(for:app:)`, down to the minute it names: old
    /// slugless names, new names with a slug, and both with a `-2` collision
    /// suffix after the slug. nil for anything this type did not write, so the
    /// caller can fall back to the file's own dates instead of inventing one.
    public static func date(fromBaseName name: String, calendar: Calendar = .current) -> Date? {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false)
        guard (6...8).contains(parts.count), parts[0] == "call" else { return nil }
        guard let date = datedPart(from: parts, calendar: calendar) else { return nil }
        guard tailIsValid(Array(parts.dropFirst(6))) else { return nil }
        return date
    }

    private static func datedPart(from parts: [Substring], calendar: Calendar) -> Date? {
        guard parts[1..<6].allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else {
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

    /// What may follow the minute: nothing, one collision number or slug, or a
    /// slug with its collision number. A number first is never a slug — slugs
    /// always carry a letter — so `call-…-33-2-3` stays unreadable.
    private static func tailIsValid(_ tail: [Substring]) -> Bool {
        if tail.isEmpty { return true }
        if tail.count > 2 { return false }
        if tail.count == 2 { return pairTailIsValid(tail[0], tail[1]) }
        return singleTailIsValid(tail[0])
    }

    private static func pairTailIsValid(_ slug: Substring, _ number: Substring) -> Bool {
        guard isSlug(slug) else { return false }
        return isCollisionNumber(number)
    }

    private static func singleTailIsValid(_ part: Substring) -> Bool {
        isCollisionNumber(part) || isSlug(part)
    }

    private static func isSlug(_ part: Substring) -> Bool {
        guard !part.isEmpty, part.count <= maxSlugLength else { return false }
        // Lowercase ASCII only, like `appSlug` writes: a hand-capitalised tail
        // is not a name this type wrote.
        guard part.allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."z").contains($0)) }) else {
            return false
        }
        return part.contains(where: { ("a"..."z").contains($0) })
    }

    private static func isCollisionNumber(_ part: Substring) -> Bool {
        !part.isEmpty && part.allSatisfy(\.isNumber)
    }

    /// Appends "-2", "-3"… while `existing` says the name is taken; the number
    /// goes after the slug, so `call-…-telegram` collides into `call-…-telegram-2`.
    public static func uniqueBaseName(
        for date: Date,
        app: String? = nil,
        calendar: Calendar = .current,
        existing: (String) -> Bool
    ) -> String {
        let base = baseName(for: date, app: app, calendar: calendar)
        guard existing(base) else { return base }
        var suffix = 2
        while existing("\(base)-\(suffix)") { suffix += 1 }
        return "\(base)-\(suffix)"
    }
}
