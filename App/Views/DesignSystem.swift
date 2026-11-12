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
    static let teal = adaptive(0x17695C, dark: 0x86D6BB)
    static let background = adaptive(0xF5F6F8, dark: 0x171A1F)
    static let surface = adaptive(0xFFFFFF, dark: 0x20242B)
    static let sidebar = adaptive(0xECEFF2, dark: 0x1B1F25)
    static let inset = adaptive(0xF0F2F5, dark: 0x292F38)
    static let selected = adaptive(0xDDEFE8, dark: 0x263F38)
    static let text = adaptive(0x202A35, dark: 0xEDF1F7)
    static let secondary = adaptive(0x566272, dark: 0xAAB6C6)
    static let border = adaptive(0xE0E5EB, dark: 0x353E49)
    static let disabledFill = adaptive(0xE5E9EE, dark: 0x303844)
    static let disabledText = adaptive(0x788493, dark: 0x96A4B6)

    static let danger = adaptive(0xB5353F, dark: 0xFF9AA3)
    static let accentFill = adaptive(0x17695C, dark: 0x296D5E)

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

/// Shared dimensions keep sheets, toolbars and record surfaces aligned.
enum AegisMetrics {
    static let panelRadius: CGFloat = 12
    static let controlRadius: CGFloat = 8
    static let pageInset: CGFloat = 24
    static let toolbarHeight: CGFloat = 56
    static var controlHeight: CGFloat {
        #if os(macOS)
        32
        #else
        44
        #endif
    }
}

enum AegisAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
    var title: String {
        switch self {
        case .system: L10n.text("appearance.system")
        case .light: L10n.text("appearance.light")
        case .dark: L10n.text("appearance.dark")
        }
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
        HStack(spacing: 10) {
            AegisMark(size: compact ? 30 : 36)
            VStack(alignment: .leading, spacing: 4) {
                Text("Aegis").aegisFont(size: compact ? 20 : 23, weight: .semibold).tracking(-0.6)
                if !compact { Text(L10n.text("ui.brandSubtitle")).aegisFont(size: 11, weight: .medium).foregroundStyle(AegisTheme.secondary) }
            }
        }.foregroundStyle(AegisTheme.text)
    }
}

/// Desktop sheets use standard controls; touch layouts retain their larger hit areas.
struct AegisButtonStyle: PrimitiveButtonStyle {
    var primary = false
    var fullWidth = false
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        #if os(macOS)
        if primary {
            Button(role: configuration.role, action: configuration.trigger) {
                configuration.label.frame(maxWidth: fullWidth ? .infinity : nil)
            }.buttonStyle(.borderedProminent).tint(AegisTheme.accentFill).controlSize(.large)
        } else {
            Button(role: configuration.role, action: configuration.trigger) {
                configuration.label.frame(maxWidth: fullWidth ? .infinity : nil)
            }.buttonStyle(.bordered).controlSize(.large)
        }
        #else
        Button(role: configuration.role, action: configuration.trigger) { configuration.label }
            .buttonStyle(AegisTouchButtonStyle(primary: primary, fullWidth: fullWidth))
        #endif
    }
}

private struct AegisTouchButtonStyle: ButtonStyle {
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
            .background(enabled ? (primary ? AegisTheme.accentFill : AegisTheme.surface) : AegisTheme.disabledFill,
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(enabled && primary ? Color.clear : AegisTheme.border))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .opacity(enabled && pressed ? 0.78 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: enabled)
    }
}
struct PrimaryButtonStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AegisButtonStyle(primary: true, fullWidth: true).makeBody(configuration: configuration)
    }
}

struct AegisNavigationButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        NavigationButtonBody(label: configuration.label, pressed: configuration.isPressed)
    }
    private struct NavigationButtonBody: View {
        let label: ButtonStyleConfiguration.Label
        let pressed: Bool
        @State private var hovered = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            label.background(enabled && (hovered || pressed) ? AegisTheme.text.opacity(pressed ? 0.07 : 0.035) : Color.clear,
                             in: RoundedRectangle(cornerRadius: AegisMetrics.controlRadius))
                .contentShape(Rectangle()).onHover { hovered = $0 }
        }
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
        32
        #endif
    }
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium)).frame(width: targetSize, height: targetSize)
                .foregroundStyle(enabled ? (prominent ? Color.white : AegisTheme.secondary) : AegisTheme.disabledText.opacity(0.55))
                .background(!enabled && prominent ? AegisTheme.disabledFill : prominent ? AegisTheme.accentFill : hovering && enabled ? AegisTheme.inset : Color.clear, in: RoundedRectangle(cornerRadius: AegisMetrics.controlRadius))
                .contentShape(RoundedRectangle(cornerRadius: AegisMetrics.controlRadius))
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
        if item.kind == .card {
            CardThumbnail(item: item, size: size)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.24).fill(tint.opacity(isSelected ? 0.14 : 0.08))
                if item.kind == .login {
                    Text(String(item.title.prefix(1)).uppercased()).aegisFont(size: size * 0.40, weight: .semibold, design: .rounded)
                } else { Image(systemName: item.kind.symbol).font(.system(size: size * 0.40, weight: .medium)) }
            }.foregroundStyle(tint).frame(width: size, height: size).accessibilityHidden(true)
        }
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
        VStack(alignment: .leading, spacing: 10) {
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
    private var inputPadding: CGFloat {
        #if os(macOS)
        9
        #else
        13
        #endif
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).aegisFont(size: 12, weight: .medium).foregroundStyle(AegisTheme.secondary)
            HStack(spacing: 10) {
                if let icon { Image(systemName: icon).font(.system(size: 15)).foregroundStyle(AegisTheme.secondary) }
                content().textFieldStyle(.plain).aegisFont(size: 14).focused($focused)
                    .frame(minHeight: 22).foregroundStyle(AegisTheme.text)
            }.padding(.horizontal, 14).padding(.vertical, inputPadding)
                .background(AegisTheme.surface, in: RoundedRectangle(cornerRadius: AegisMetrics.controlRadius))
                .overlay(RoundedRectangle(cornerRadius: AegisMetrics.controlRadius).stroke(focused ? AegisTheme.teal.opacity(0.65) : AegisTheme.border, lineWidth: focused ? 1.5 : 1))
        }
    }
}

struct AegisSheetHeader: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    var close: (() -> Void)? = nil
    var closeDisabled = false
    private var compact: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: compact ? 16 : 20, weight: .medium)).foregroundStyle(AegisTheme.teal)
                    .frame(width: compact ? 34 : 46, height: compact ? 34 : 46).background(AegisTheme.selected, in: RoundedRectangle(cornerRadius: compact ? 9 : 14))
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(title).aegisFont(size: compact ? 17 : 23, weight: .semibold).tracking(-0.5).foregroundStyle(AegisTheme.text)
                if let subtitle { Text(subtitle).aegisFont(size: 12).foregroundStyle(AegisTheme.secondary) }
            }
            Spacer(minLength: 8)
            if let close {
                AegisIconButton(symbol: "xmark", label: L10n.text("action.close"), action: close)
                    .disabled(closeDisabled).keyboardShortcut(.cancelAction)
            }
        }.padding(.horizontal, AegisMetrics.pageInset).padding(.vertical, compact ? 18 : 20)
            .background(AegisTheme.surface)
            .overlay(alignment: .bottom) { Rectangle().fill(AegisTheme.border).frame(height: 0.5) }
    }
}

struct AegisEmptyState: View {
    let title: String
    let message: String
    var symbol = "lock.shield"
    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16).fill(AegisTheme.inset).frame(width: 64, height: 64)
                Image(systemName: symbol).font(.system(size: 25, weight: .regular)).foregroundStyle(AegisTheme.teal)
            }
            VStack(spacing: 8) {
                Text(title).aegisFont(size: 18, weight: .semibold).foregroundStyle(AegisTheme.text)
                Text(message).aegisFont(size: 13).lineSpacing(4).foregroundStyle(AegisTheme.secondary)
            }.multilineTextAlignment(.center).frame(maxWidth: 300)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    func aegisFont(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(AegisScaledFont(size: size, weight: weight, design: design))
    }
    func aegisSurface(radius: CGFloat = AegisMetrics.panelRadius) -> some View {
        background(AegisTheme.surface, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(AegisTheme.border, lineWidth: 0.5))
    }
    func aegisCard() -> some View { padding(20).aegisSurface() }
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
