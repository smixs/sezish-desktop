import SwiftUI
import SezishCore

/// hex's settings language in sezish colours: one bordered card of rows, an icon,
/// a title with an optional hint, the control on the right.
struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Brand.bgSoft, in: RoundedRectangle(cornerRadius: Brand.Radius.small))
            .overlay(RoundedRectangle(cornerRadius: Brand.Radius.small)
                .strokeBorder(Brand.faint, lineWidth: 1))
    }
}

struct SettingsRow<Trailing: View>: View {
    let icon: String
    let title: String
    var hint: String?
    var divider = true
    @ViewBuilder let trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(Brand.muted)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13)).foregroundStyle(Brand.text)
                    if let hint {
                        Text(hint).font(.system(size: 11)).foregroundStyle(Brand.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                trailing
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 40)
            if divider { BrandDivider().padding(.leading, 44) }
        }
    }
}

/// A row that opens a sub-page: the current value and a chevron, the whole row clickable.
struct SettingsLinkRow<Destination: View>: View {
    let icon: String
    let title: String
    let value: String
    var divider = true
    @ViewBuilder let destination: Destination

    var body: some View {
        NavigationLink {
            destination
        } label: {
            SettingsRow(icon: icon, title: title, divider: divider) {
                HStack(spacing: 6) {
                    Text(value).font(.system(size: 13)).foregroundStyle(Brand.text)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Brand.muted)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SettingsSectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Brand.muted)
            .padding(.leading, 4)
    }
}

/// The page title in the detail column, left-aligned like hex.
struct SettingsPageTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Brand.text)
    }
}

/// A search field in the brand's soft fill.
struct SettingsSearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Brand.muted)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Brand.muted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Brand.bgSoft, in: RoundedRectangle(cornerRadius: Brand.Radius.tiny))
        .overlay(RoundedRectangle(cornerRadius: Brand.Radius.tiny).strokeBorder(Brand.faint, lineWidth: 1))
    }
}

/// "Сегодня" / "Вчера" / "4 ноября" over a day's rows.
struct DayHeader: View {
    let day: Date
    let strings: SettingsStrings
    let locale: Locale

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Brand.muted)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .padding(.leading, 4)
    }

    private var label: String {
        switch DayGrouping.relative(day, now: Date()) {
        case .today: strings.today
        case .yesterday: strings.yesterday
        case .earlier: day.formatted(.dateTime.day().month(.wide).locale(locale))
        }
    }
}
