import AegisCore
import SwiftUI

struct CardPalette {
    let top: Color
    let bottom: Color
    let ink: Color
    let foil: Color
    let isLight: Bool
    let nameKey: String

    init(brand: CardBrand?, type: PaymentCardType?) {
        let colors: (UInt32, UInt32, UInt32, UInt32, Bool, String)
        switch (brand, type) {
        case (.unionPay, .debit): colors = (0x113F38, 0x286154, 0xF3F3DD, 0xB7D5B9, false, "card.style.jade")
        case (.unionPay, .credit): colors = (0x4F1828, 0x863D43, 0xFFF1DF, 0xE2B681, false, "card.style.vermilion")
        case (.visa, .debit): colors = (0x102F63, 0x215A91, 0xF0F6FF, 0x96CDEA, false, "card.style.ocean")
        case (.visa, .credit): colors = (0xF1DDB2, 0xD1AD70, 0x302A24, 0x765C35, true, "card.style.champagne")
        case (.mastercard, .debit): colors = (0x663225, 0xA34E35, 0xFFF0E1, 0xE8B487, false, "card.style.copper")
        case (.mastercard, .credit): colors = (0x1C242E, 0x394553, 0xF1F3F6, 0xB6C2D0, false, "card.style.obsidian")
        case (.centurion, .debit): colors = (0xE4E9E5, 0xABBDB9, 0x253D39, 0x4C6A60, true, "card.style.platinum")
        case (.centurion, .credit): colors = (0x14191D, 0x2B2C2D, 0xEEDBB6, 0xC6A66B, false, "card.style.blackGold")
        default: colors = (0x203D38, 0x3D5950, 0xF4F1E5, 0xC5CBB9, false, "card.style.classic")
        }
        top = Self.color(colors.0); bottom = Self.color(colors.1)
        ink = Self.color(colors.2); foil = Self.color(colors.3)
        isLight = colors.4; nameKey = colors.5
    }

    var gradient: LinearGradient {
        LinearGradient(colors: [top, bottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func color(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 255) / 255,
              green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
}

struct BankCardView: View {
    let item: VaultItem
    static let aspectRatio: CGFloat = 85.60 / 53.98
    private let canvasWidth: CGFloat = 340
    private var palette: CardPalette { CardPalette(brand: item.cardBrand, type: item.cardType) }

    var body: some View {
        GeometryReader { geometry in
            face
                .frame(width: canvasWidth, height: canvasWidth / Self.aspectRatio)
                .background { CardArtwork(brand: item.cardBrand, type: item.cardType, palette: palette) }
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(palette.ink.opacity(palette.isLight ? 0.13 : 0.18), lineWidth: 0.7)
                }
                .scaleEffect(geometry.size.width / canvasWidth, anchor: .topLeading)
        }
        .aspectRatio(Self.aspectRatio, contentMode: .fit)
        .frame(maxWidth: 540)
        .shadow(color: palette.bottom.opacity(0.16), radius: 16, x: 0, y: 9)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.title, item.cardDescription, item.maskedCardNumber].joined(separator: ", "))
        .accessibilityIdentifier("bankCardPreview")
        .privacySensitive()
    }

    // The card is a proportional graphic; scalable, selectable values remain in the detail fields.
    private var face: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title.isEmpty ? L10n.text("card.previewTitle") : item.title)
                        .font(.system(size: 14, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    Text(item.cardType?.title ?? L10n.text("card.type.unspecified"))
                        .font(.system(size: 8, weight: .semibold)).tracking(1)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(palette.ink.opacity(0.09), in: Capsule())
                }.frame(maxWidth: .infinity, alignment: .leading)
                CardBrandMark(brand: item.cardBrand, ink: palette.ink)
                    .frame(width: 74, height: 32, alignment: .trailing).accessibilityHidden(true)
            }
            Spacer(minLength: 16)
            HStack(spacing: 11) {
                CardChip().fill(palette.foil.opacity(0.8)).frame(width: 32, height: 24)
                    .overlay { CardChipLines().stroke(palette.top.opacity(0.65), lineWidth: 0.7) }
                Image(systemName: "wave.3.right").font(.system(size: 17, weight: .light)).opacity(0.65)
                Spacer()
            }.accessibilityHidden(true)
            Spacer(minLength: 16)
            Text(item.maskedCardNumber).font(.system(size: 20, weight: .medium, design: .monospaced))
                .tracking(0.4).lineLimit(1).minimumScaleFactor(0.65)
            Spacer(minLength: 18)
            HStack(alignment: .bottom, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("field.cardholder")).font(.system(size: 8, weight: .medium)).opacity(0.82)
                    Text(item.cardholder.isEmpty ? "—" : item.cardholder)
                        .font(.system(size: 10, weight: .medium)).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 5) {
                    Text(L10n.text("field.expiry")).font(.system(size: 8, weight: .medium)).opacity(0.82)
                    Text(item.expiry.isEmpty ? "—" : item.expiry)
                        .font(.system(size: 10, weight: .medium, design: .monospaced)).lineLimit(1)
                }
            }
        }
        .foregroundStyle(palette.ink).padding(21)
    }
}

struct CardThumbnail: View {
    let item: VaultItem
    var size: CGFloat
    private var palette: CardPalette { CardPalette(brand: item.cardBrand, type: item.cardType) }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.21).fill(palette.gradient)
            CardMotif(brand: item.cardBrand, credit: item.cardType == .credit)
                .stroke(palette.foil.opacity(0.24), lineWidth: 0.6)
            CardBrandMark(brand: item.cardBrand, ink: palette.ink, compact: true)
                .padding(size * 0.13)
        }
        .frame(width: size, height: size / BankCardView.aspectRatio)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.15))
        .overlay { RoundedRectangle(cornerRadius: size * 0.15).strokeBorder(palette.ink.opacity(0.18), lineWidth: 0.6) }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct CardAppearancePicker: View {
    @Binding var item: VaultItem
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            BankCardView(item: item).frame(maxWidth: .infinity)
                .padding(.bottom, 6)
            HStack {
                Text(L10n.text("card.appearance")).aegisFont(size: 12, weight: .medium).foregroundStyle(AegisTheme.secondary)
                Spacer()
                if item.cardBrand != nil || item.cardType != nil {
                    Button(L10n.text("card.clearAppearance")) { item.cardBrand = nil; item.cardType = nil }
                        .aegisFont(size: 11).buttonStyle(.plain).foregroundStyle(AegisTheme.teal)
                        .frame(minHeight: 44)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 180 : 115), spacing: 10)], spacing: 10) {
                ForEach(CardBrand.allCases) { brand in
                    brandButton(brand)
                }
            }
            HStack(spacing: 10) {
                ForEach(PaymentCardType.allCases) { type in
                    Button { item.cardType = type } label: {
                        HStack(spacing: 8) {
                            Image(systemName: type == .debit ? "banknote" : "creditcard")
                            Text(type.title)
                        }.aegisFont(size: 13, weight: .medium)
                            .frame(maxWidth: .infinity, minHeight: 46)
                            .foregroundStyle(item.cardType == type ? AegisTheme.teal : AegisTheme.secondary)
                            .background(item.cardType == type ? AegisTheme.selected : AegisTheme.surface, in: RoundedRectangle(cornerRadius: 11))
                            .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(item.cardType == type ? AegisTheme.teal.opacity(0.4) : AegisTheme.border) }
                            .contentShape(RoundedRectangle(cornerRadius: 11))
                    }.buttonStyle(.plain).accessibilityAddTraits(item.cardType == type ? [.isSelected] : [])
                        .accessibilityIdentifier("cardType-\(type.rawValue)")
                }
            }
        }
    }

    private func brandButton(_ brand: CardBrand) -> some View {
        let selected = item.cardBrand == brand
        return Button { item.cardBrand = brand } label: {
            VStack(spacing: 8) {
                CardBrandMark(brand: brand, ink: AegisTheme.text).frame(height: 30)
                Text(brand.title).aegisFont(size: 11, weight: .medium).lineLimit(1).minimumScaleFactor(0.8)
            }.foregroundStyle(AegisTheme.text)
                .frame(maxWidth: .infinity).padding(.vertical, 15).padding(.horizontal, 8)
                .background(selected ? AegisTheme.selected : AegisTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? AegisTheme.teal.opacity(0.5) : AegisTheme.border, lineWidth: selected ? 1.5 : 1) }
                .overlay(alignment: .topTrailing) {
                    if selected {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(AegisTheme.teal)
                            .padding(7).accessibilityHidden(true)
                    }
                }.contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).accessibilityLabel(brand.title)
            .accessibilityAddTraits(selected ? [.isSelected] : []).accessibilityIdentifier("cardBrand-\(brand.rawValue)")
    }
}

private struct CardArtwork: View {
    let brand: CardBrand?
    let type: PaymentCardType?
    let palette: CardPalette
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                palette.gradient
                LinearGradient(colors: [.white.opacity(0.12), .clear, .black.opacity(0.08)], startPoint: .top, endPoint: .bottom)
                CardMotif(brand: brand, credit: type == .credit)
                    .stroke(palette.foil.opacity(brand == .centurion ? 0.16 : 0.23), lineWidth: 0.8)
                if brand == .centurion {
                    CenturionMedallion().stroke(palette.foil.opacity(0.19), style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
                        .frame(width: proxy.size.height * 0.8, height: proxy.size.height * 0.8)
                        .position(x: proxy.size.width * 0.73, y: proxy.size.height * 0.58)
                }
            }
        }.accessibilityHidden(true)
    }
}

struct CardBrandMark: View {
    let brand: CardBrand?
    var ink: Color
    var compact = false
    var body: some View {
        Group {
            switch brand {
            case .unionPay:
                ZStack {
                    HStack(spacing: -2) {
                        ForEach([UInt32(0xB52C42), 0x126484, 0x147567], id: \.self) { hex in
                            RoundedRectangle(cornerRadius: 4).fill(CardPalette.color(hex))
                        }
                    }.rotationEffect(.degrees(-8))
                    Text(compact ? L10n.text("card.brand.unionPay") : "UnionPay")
                        .font(.system(size: compact ? 10 : 11, weight: .heavy, design: .rounded)).italic().foregroundStyle(.white)
                        .minimumScaleFactor(0.6).lineLimit(1).padding(.horizontal, 3)
                }.frame(maxWidth: compact ? 36 : 74, maxHeight: compact ? 18 : 30)
            case .visa:
                Text("VISA").font(.system(size: compact ? 15 : 28, weight: .black)).italic().tracking(-1)
                    .foregroundStyle(ink).minimumScaleFactor(0.6).lineLimit(1)
            case .mastercard:
                HStack(spacing: compact ? -7 : -11) {
                    Circle().fill(CardPalette.color(0xEB3E36))
                    Circle().fill(CardPalette.color(0xF7AA32)).opacity(0.94)
                }.frame(width: compact ? 31 : 57, height: compact ? 19 : 34)
            case .centurion:
                if compact {
                    CenturionMedallion().stroke(ink, style: StrokeStyle(lineWidth: 0.8, lineCap: .round, lineJoin: .round))
                        .frame(width: 24, height: 24)
                } else {
                    VStack(spacing: 0) {
                        Text("AMERICAN")
                        Text("EXPRESS")
                    }.font(.system(size: 10, weight: .heavy, design: .rounded)).tracking(-0.3)
                        .foregroundStyle(ink).padding(.horizontal, 6).padding(.vertical, 4)
                        .overlay { RoundedRectangle(cornerRadius: 3).stroke(ink.opacity(0.7), lineWidth: 0.7) }
                }
            case nil:
                Text("Aegis").font(.system(size: compact ? 11 : 21, weight: .medium, design: .serif)).foregroundStyle(ink)
            }
        }.accessibilityHidden(true)
    }
}

private struct CardChip: Shape {
    func path(in rect: CGRect) -> Path { Path(roundedRect: rect, cornerRadius: rect.height * 0.21) }
}

private struct CardChipLines: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            let center = CGRect(x: r.width * 0.3, y: 0, width: r.width * 0.4, height: r.height)
            p.addRoundedRect(in: center, cornerSize: CGSize(width: 3, height: 3))
            for fraction in [CGFloat(0.33), 0.67] {
                p.move(to: CGPoint(x: 0, y: r.height * fraction)); p.addLine(to: CGPoint(x: r.width * 0.3, y: r.height * fraction))
                p.move(to: CGPoint(x: r.width * 0.7, y: r.height * fraction)); p.addLine(to: CGPoint(x: r.width, y: r.height * fraction))
            }
        }
    }
}

private struct CardMotif: Shape {
    let brand: CardBrand?
    let credit: Bool
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        switch brand {
        case .unionPay:
            for i in 0..<13 {
                let shift = CGFloat(i) * w * 0.035
                p.move(to: CGPoint(x: w * 0.34 + shift, y: h * 1.1))
                p.addCurve(to: CGPoint(x: w * 1.1, y: -h * 0.2 + shift * 0.4),
                           control1: CGPoint(x: w * (credit ? 0.95 : 0.4) + shift, y: h * 0.7),
                           control2: CGPoint(x: w * 0.62 + shift, y: h * 0.05))
            }
        case .visa:
            for i in 0..<15 {
                let y = CGFloat(i) * h * 0.042
                p.move(to: CGPoint(x: w * 0.28, y: h * 1.25 - y))
                p.addCurve(to: CGPoint(x: w * 1.15, y: h * 0.56 - y),
                           control1: CGPoint(x: w * 0.6, y: h * (credit ? 0.3 : 1.28) - y),
                           control2: CGPoint(x: w * 0.76, y: h * (credit ? 1.05 : 0.34) - y))
            }
        case .mastercard:
            for i in 0..<12 {
                let diameter = h * 0.72 + CGFloat(i) * h * 0.07
                for center in [CGFloat(0.67), 0.91] {
                    p.addEllipse(in: CGRect(x: w * center - diameter / 2, y: h * 0.62 - diameter / 2,
                                            width: diameter, height: diameter))
                }
            }
        case .centurion:
            p.addRoundedRect(in: rect.insetBy(dx: 10, dy: 10), cornerSize: CGSize(width: 11, height: 11))
            p.addRoundedRect(in: rect.insetBy(dx: 14, dy: 14), cornerSize: CGSize(width: 8, height: 8))
            for i in 0..<30 {
                let x = CGFloat(i) * w / 20
                p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x - h * 0.7, y: h))
            }
        case nil:
            p.addEllipse(in: CGRect(x: w * 0.48, y: -h * 0.4, width: w, height: w))
        }
        return p
    }
}

/// Original geometric cameo, drawn as vectors so it remains crisp on both platforms.
private struct CenturionMedallion: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        func v(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        p.addEllipse(in: rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.03))
        p.addEllipse(in: rect.insetBy(dx: rect.width * 0.12, dy: rect.height * 0.07))
        p.move(to: v(0.28, 0.45))
        p.addCurve(to: v(0.7, 0.34), control1: v(0.22, 0.16), control2: v(0.64, 0.12))
        p.addLine(to: v(0.75, 0.4)); p.addLine(to: v(0.31, 0.48))
        p.move(to: v(0.62, 0.43)); p.addLine(to: v(0.65, 0.51))
        p.addLine(to: v(0.73, 0.57)); p.addLine(to: v(0.65, 0.6))
        p.addLine(to: v(0.65, 0.68)); p.addLine(to: v(0.54, 0.71))
        p.addLine(to: v(0.54, 0.79)); p.addLine(to: v(0.71, 0.86))
        p.addLine(to: v(0.29, 0.86)); p.addLine(to: v(0.43, 0.75))
        p.addLine(to: v(0.39, 0.58)); p.addLine(to: v(0.32, 0.55)); p.addLine(to: v(0.34, 0.46))
        p.move(to: v(0.39, 0.32)); p.addCurve(to: v(0.59, 0.27), control1: v(0.44, 0.24), control2: v(0.55, 0.23))
        p.move(to: v(0.56, 0.5)); p.addLine(to: v(0.61, 0.5))
        return p
    }
}
