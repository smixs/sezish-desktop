import SwiftUI

/// Primary action: brand gradient fill, white text, warm glow that grows on hover —
/// the site's `.btn-primary` translated to SwiftUI.
struct BrandPrimaryButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, compact: compact)
    }

    // ButtonStyle itself is stateless; hover lives in a private wrapper view.
    private struct HoverBody: View {
        let configuration: Configuration
        let compact: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: compact ? 12 : 13, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, compact ? 10 : 14)
                .padding(.vertical, compact ? 5 : 8)
                .frame(maxWidth: compact ? nil : .infinity)
                .background(
                    // Hover brightens/saturates the ramp in place — the site's
                    // filter recipe, not a second flat color.
                    RoundedRectangle(cornerRadius: Brand.Radius.small)
                        .fill(Brand.gradient)
                        .brightness(hovering ? 0.10 : 0)
                        .saturation(hovering ? 1.08 : 1.0)
                )
                .shadow(
                    color: Brand.glow.opacity(hovering ? 1.0 : 0.7),
                    radius: hovering ? 14 : 8,
                    y: hovering ? 6 : 4
                )
                .offset(y: hovering ? -1 : 0)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(.brandExpoOutFast, value: hovering)
                .animation(.brandExpoOutFast, value: configuration.isPressed)
                .onHover { hovering = $0 }
        }
    }
}

/// Menu/pane row: full-width label with a faint hover wash.
struct BrandRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    hovering ? Brand.hover : .clear,
                    in: RoundedRectangle(cornerRadius: Brand.Radius.control)
                )
                .contentShape(RoundedRectangle(cornerRadius: Brand.Radius.control))
                .opacity(configuration.isPressed ? 0.7 : 1)
                .onHover { hovering = $0 }
        }
    }
}

/// Secondary action: soft fill with a 1px border that wakes up on hover.
struct BrandSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration)
    }

    private struct HoverBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Brand.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Brand.bgSoft, in: RoundedRectangle(cornerRadius: Brand.Radius.control))
                .overlay(
                    RoundedRectangle(cornerRadius: Brand.Radius.control)
                        .strokeBorder(hovering ? Brand.muted : Brand.faint, lineWidth: 1)
                )
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(.brandExpoOutFast, value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

struct BrandSectionHeader: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .kerning(0.2)
            .foregroundStyle(Brand.muted)
    }
}

struct BrandDivider: View {
    var body: some View {
        Rectangle().fill(Brand.faint).frame(height: 1)
    }
}

struct BrandProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Brand.faint)
                Capsule()
                    .fill(Brand.gradient)
                    .frame(width: max(5, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 5)
        .animation(.brandExpoOut, value: fraction)
    }
}
