import AegisCore
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

enum AegisTheme {
    static let navy = Color(red: 0.07, green: 0.16, blue: 0.16)
    static let gold = adaptive(0x80602D, dark: 0xD9B778)
    static let teal = adaptive(0x27635B, dark: 0x83C3B4)
    static let background = adaptive(0xF7F8F5, dark: 0x171C1B)
    static let surface = adaptive(0xFFFFFF, dark: 0x202725)
    static let sidebar = adaptive(0xEEF1EB, dark: 0x19211E)
    static let inset = adaptive(0xF3F5F0, dark: 0x29322F)
    static let selected = adaptive(0xE2EDE5, dark: 0x2B443A)
    static let text = adaptive(0x23352F, dark: 0xECF2ED)
    static let secondary = adaptive(0x53645A, dark: 0xA4B1A9)
    static let border = adaptive(0xE4E9E2, dark: 0x35413A)
    static let disabledFill = adaptive(0xE6EAE5, dark: 0x303A34)
    static let disabledText = adaptive(0x738077, dark: 0x96A49B)

    static func adaptive(_ light: UInt32, dark: UInt32) -> Color {
        func components(_ hex: UInt32) -> (CGFloat, CGFloat, CGFloat) {
            (CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255)
        }
        #if os(iOS)
        return Color(uiColor: UIColor { traits in
            let (r, g, b) = components(traits.userInterfaceStyle == .dark ? dark : light)
            return UIColor(red: r, green: g, blue: b, alpha: 1)
        })
        #else
        return Color(nsColor: NSColor(name: nil) { appearance in
            let (r, g, b) = components(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        })
        #endif
    }
}

struct AegisMark: View {
    var size: CGFloat = 64
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.29, blue: 0.26), AegisTheme.navy], startPoint: .topLeading, endPoint: .bottomTrailing))
            ShieldShape().stroke(Color(red: 0.86, green: 0.72, blue: 0.46), style: StrokeStyle(lineWidth: size * 0.036, lineCap: .round, lineJoin: .round))
                .padding(size * 0.23)
            VStack(spacing: -size * 0.012) {
                Circle().frame(width: size * 0.11, height: size * 0.11)
                Trapezoid().frame(width: size * 0.10, height: size * 0.13)
            }.foregroundStyle(Color(red: 0.86, green: 0.72, blue: 0.46))
        }.frame(width: size, height: size).accessibilityLabel(L10n.text("brand.logo"))
    }
}
private struct ShieldShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height) }
        p.move(to: point(0.5, 0)); p.addLine(to: point(0.96, 0.18)); p.addLine(to: point(0.91, 0.58))
        p.addCurve(to: point(0.5, 1), control1: point(0.88, 0.79), control2: point(0.67, 0.92))
        p.addCurve(to: point(0.09, 0.58), control1: point(0.33, 0.92), control2: point(0.12, 0.79))
        p.addLine(to: point(0.04, 0.18)); p.closeSubpath(); return p
    }
}
private struct Trapezoid: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.width * 0.3, y: 0)); p.addLine(to: CGPoint(x: rect.width * 0.7, y: 0))
            p.addLine(to: CGPoint(x: rect.width, y: rect.height)); p.addLine(to: CGPoint(x: 0, y: rect.height)); p.closeSubpath()
        }
    }
}

struct AegisBrand: View {
    var compact = false
    var body: some View {
        HStack(spacing: 12) {
            AegisMark(size: compact ? 32 : 42)
            VStack(alignment: .leading, spacing: 4) {
                Text("Aegis").aegisFont(size: compact ? 22 : 26, weight: .semibold, design: .serif).tracking(-0.6)
                if !compact { Text(L10n.text("ui.brandSubtitle")).aegisFont(size: 11, weight: .medium).foregroundStyle(AegisTheme.secondary) }
            }
        }.foregroundStyle(AegisTheme.text)
    }
}

struct AegisButtonStyle: ButtonStyle {
    var primary = false
    var fullWidth = false
    func makeBody(configuration: Configuration) -> some View {
        AegisButtonBody(label: configuration.label, primary: primary, fullWidth: fullWidth,
                        pressed: configuration.isPressed)
    }
}

/// Read the environment on an installed View, including when a ButtonStyle wraps another style.
private struct AegisButtonBody: View {
    let label: ButtonStyleConfiguration.Label
    let primary: Bool
    let fullWidth: Bool
    let pressed: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        label.aegisFont(size: 14, weight: .semibold)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 20)
            .padding(.horizontal, 18).padding(.vertical, 12)
            .foregroundStyle(enabled ? (primary ? Color.white : AegisTheme.text) : AegisTheme.disabledText)
            .background(enabled ? (primary ? AegisTheme.navy : AegisTheme.surface) : AegisTheme.disabledFill,
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(enabled && primary ? Color.clear : AegisTheme.border))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .opacity(enabled && pressed ? 0.78 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: enabled)
    }
}
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AegisButtonStyle(primary: true, fullWidth: true).makeBody(configuration: configuration)
    }
}
struct AegisIconButton: View {
    let symbol: String
    let label: String
    var prominent = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    private var targetSize: CGFloat {
        #if os(iOS)
        44
        #else
        38
        #endif
    }
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium)).frame(width: targetSize, height: targetSize)
                .foregroundStyle(enabled ? (prominent ? Color.white : AegisTheme.secondary) : AegisTheme.disabledText.opacity(0.55))
                .background(!enabled && prominent ? AegisTheme.disabledFill : prominent ? AegisTheme.navy : hovering && enabled ? AegisTheme.inset : Color.clear, in: RoundedRectangle(cornerRadius: 11))
                .contentShape(RoundedRectangle(cornerRadius: 11))
        }.buttonStyle(.plain).onHover { hovering = enabled && $0 }.help(label).accessibilityLabel(label)
            .onChange(of: enabled) { _, value in if !value { hovering = false } }
    }
}

struct ItemIcon: View {
    let item: VaultItem
    var isSelected = false
    var size: CGFloat = 44
    private var tint: Color {
        switch item.kind {
        case .card: AegisTheme.adaptive(0x9C7640, dark: 0xE4C286)
        case .note: AegisTheme.adaptive(0x577995, dark: 0x94BEDC)
        case .login:
            switch item.title.lowercased() {
            case "apple", "github": AegisTheme.text
            case "figma": AegisTheme.adaptive(0x95646E, dark: 0xDFAAB5)
            default: AegisTheme.teal
            }
        }
    }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.29).fill(tint.opacity(isSelected ? 0.14 : 0.08))
            if item.kind == .login {
                Text(String(item.title.prefix(1)).uppercased()).aegisFont(size: size * 0.40, weight: .semibold, design: .rounded)
            } else { Image(systemName: item.kind.symbol).font(.system(size: size * 0.40, weight: .medium)) }
        }.foregroundStyle(tint).frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct AegisPill: View {
    let title: String
    var symbol: String? = nil
    var tint = AegisTheme.teal
    var body: some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
            Text(title).aegisFont(size: 11, weight: .medium)
        }.foregroundStyle(tint).padding(.horizontal, 9).padding(.vertical, 5)
            .background(tint.opacity(0.08), in: Capsule())
    }
}

struct AegisSection<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).aegisFont(size: 13, weight: .semibold).foregroundStyle(AegisTheme.text)
                if let subtitle { Text(subtitle).aegisFont(size: 12).foregroundStyle(AegisTheme.secondary).lineSpacing(3) }
            }.padding(.horizontal, 2)
            VStack(spacing: 0, content: content).aegisSurface()
        }
    }
}

struct AegisInput<Content: View>: View {
    let title: String
    var icon: String? = nil
    @ViewBuilder var content: () -> Content
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).aegisFont(size: 12, weight: .medium).foregroundStyle(AegisTheme.secondary)
            HStack(spacing: 10) {
                if let icon { Image(systemName: icon).font(.system(size: 15)).foregroundStyle(AegisTheme.secondary) }
                content().textFieldStyle(.plain).aegisFont(size: 15).focused($focused)
                    .frame(minHeight: 22).foregroundStyle(AegisTheme.text)
            }.padding(.horizontal, 14).padding(.vertical, 13)
                .background(AegisTheme.surface, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(focused ? AegisTheme.teal.opacity(0.65) : AegisTheme.border, lineWidth: focused ? 1.5 : 1))
        }
    }
}

struct AegisSheetHeader: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    var close: (() -> Void)? = nil
    var closeDisabled = false
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 20, weight: .medium)).foregroundStyle(AegisTheme.teal)
                    .frame(width: 46, height: 46).background(AegisTheme.selected, in: RoundedRectangle(cornerRadius: 14))
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(title).aegisFont(size: 23, weight: .semibold).tracking(-0.5).foregroundStyle(AegisTheme.text)
                if let subtitle { Text(subtitle).aegisFont(size: 12).foregroundStyle(AegisTheme.secondary) }
            }
            Spacer(minLength: 8)
            if let close { AegisIconButton(symbol: "xmark", label: L10n.text("action.close"), action: close).disabled(closeDisabled) }
        }.padding(24)
    }
}

struct AegisEmptyState: View {
    let title: String
    let message: String
    var symbol = "lock.shield"
    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 24).fill(AegisTheme.selected).frame(width: 88, height: 88)
                Image(systemName: symbol).font(.system(size: 32, weight: .light)).foregroundStyle(AegisTheme.teal)
            }
            VStack(spacing: 8) {
                Text(title).aegisFont(size: 20, weight: .semibold).foregroundStyle(AegisTheme.text)
                Text(message).aegisFont(size: 13).lineSpacing(4).foregroundStyle(AegisTheme.secondary)
            }.multilineTextAlignment(.center).frame(maxWidth: 300)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    func aegisFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(AegisScaledFont(size: size, weight: weight, design: design))
    }
    func aegisSurface(radius: CGFloat = 16) -> some View {
        background(AegisTheme.surface, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(AegisTheme.border.opacity(0.8)))
    }
    func aegisCard() -> some View { padding(22).aegisSurface() }
    func aegisSheetSize(width: CGFloat = 600, height: CGFloat = 700) -> some View {
        #if os(macOS)
        frame(minWidth: width, idealWidth: width, maxWidth: width + 100, minHeight: min(height, 520), idealHeight: height, maxHeight: height + 100)
        #else
        presentationDragIndicator(.visible).presentationCornerRadius(28)
        #endif
    }
    func aegisNoCapitalization() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
        #else
        self
        #endif
    }
}

private struct AegisScaledFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    init(size: CGFloat, weight: Font.Weight, design: Font.Design) {
        let style: Font.TextStyle = size >= 28 ? .title : size >= 20 ? .title2 : size >= 15 ? .body : .caption
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight; self.design = design
    }
    func body(content: Content) -> some View { content.font(.system(size: size, weight: weight, design: design)) }
}
