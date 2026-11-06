import AegisCore
import SwiftUI

struct CardPalette {
    let top: Color
    let bottom: Color
    let ink: Color
    let foil: Color

    init(brand: CardBrand?, type: PaymentCardType?) {
        let colors: (UInt32, UInt32, UInt32, UInt32)
        switch (brand, type) {
        case (.unionPay, .debit): colors = (0x294D7B, 0x152440, 0xF2F6FF, 0x7FB8F6)
        case (.unionPay, .credit): colors = (0x303B50, 0x171D2A, 0xF2F4FA, 0xA9BAD6)
        case (.visa, .debit): colors = (0x24528D, 0x112A51, 0xF0F5FF, 0x6BB5FF)
        case (.visa, .credit): colors = (0x2C3D68, 0x121B30, 0xF2F4FF, 0x9DB8F5)
        case (.mastercard, .debit): colors = (0x514747, 0x2B282D, 0xF7F3F0, 0xDFC2A3)
        case (.mastercard, .credit): colors = (0x34343A, 0x171A22, 0xF5F4F1, 0xDCC7A8)
        case (.americanExpress, .debit): colors = (0x738092, 0x3B475A, 0xFFFFFF, 0xD4E0F1)
        case (.americanExpress, .credit): colors = (0x38414F, 0x151B24, 0xF2F5FA, 0xA9B7CD)
        default: colors = (0x35424D, 0x18242D, 0xF2F5F7, 0xB1C3CE)
        }
        top = Self.color(colors.0); bottom = Self.color(colors.1)
        ink = Self.color(colors.2); foil = Self.color(colors.3)
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
                .background { CardArtwork(brand: item.cardBrand, palette: palette) }
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [palette.foil.opacity(0.65), .white.opacity(0.07), palette.foil.opacity(0.2)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.6)
                }
                .scaleEffect(geometry.size.width / canvasWidth, anchor: .topLeading)
        }
        .aspectRatio(Self.aspectRatio, contentMode: .fit)
        .frame(maxWidth: 540)
        .shadow(color: palette.bottom.opacity(0.2), radius: 12, x: 0, y: 7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([item.title, item.cardDescription, item.maskedCardNumber].joined(separator: ", "))
        .accessibilityIdentifier("bankCardPreview")
        .privacySensitive()
    }

    // The card is a proportional graphic; scalable, selectable values remain in the detail fields.
    private var face: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                CardBrandMark(brand: item.cardBrand, ink: palette.ink)
                    .frame(width: 74, height: 36, alignment: .leading).accessibilityHidden(true)
                Rectangle().fill(palette.ink.opacity(0.6)).frame(width: 0.5, height: 27)
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.cardType?.title ?? L10n.text("card.type.unspecified"))
                        .font(.system(size: 13, weight: .medium)).tracking(1.1).lineLimit(1)
                    if let type = item.cardType {
                        Text(L10n.text(type == .credit ? "card.face.credit" : "card.face.debit"))
                            .font(.system(size: 6.5, weight: .regular)).tracking(1.7).opacity(0.85)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(item.title.isEmpty ? L10n.text("card.previewTitle") : item.title)
                .font(.system(size: 10, weight: .medium)).lineLimit(1).opacity(0.8).padding(.top, 9)
            Spacer(minLength: 8)
            HStack(spacing: 11) {
                CardChip().fill(LinearGradient(colors: [palette.foil.opacity(0.8), palette.foil.opacity(0.4)],
                                              startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 28, height: 21)
                    .overlay { CardChipLines().stroke(palette.top.opacity(0.65), lineWidth: 0.7) }
                Image(systemName: "wave.3.right").font(.system(size: 15, weight: .light)).opacity(0.55)
                Spacer()
            }.accessibilityHidden(true)
            Spacer(minLength: 10)
            Text(item.maskedCardNumber).font(.system(size: 19, weight: .medium, design: .monospaced))
                .tracking(0.4).lineLimit(1).minimumScaleFactor(0.65)
            Spacer(minLength: 14)
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
            CardArc().stroke(palette.foil.opacity(0.6), lineWidth: 0.5)
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Label(L10n.text("card.appearance"), systemImage: "rectangle.on.rectangle")
                    .aegisFont(size: 12, weight: .semibold).foregroundStyle(AegisTheme.text)
                Spacer(minLength: 0)
                Button {
                    item.cardBrand = nil; item.cardType = nil
                } label: {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AegisTheme.secondary).frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(item.cardBrand == nil && item.cardType == nil)
                .opacity(item.cardBrand == nil && item.cardType == nil ? 0.4 : 1)
                .accessibilityLabel(L10n.text("card.clearAppearance"))
                .accessibilityIdentifier("resetCardAppearance")
                .help(L10n.text("card.clearAppearance"))
            }
            .padding(.top, -8).padding(.trailing, -8).padding(.bottom, -8)

            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 18) {
                    centeredPreview
                    controls
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 20) {
                        preview(width: 240)
                        controls.frame(minWidth: 270)
                    }
                    VStack(alignment: .leading, spacing: 18) {
                        centeredPreview
                        controls
                    }
                }
            }
        }
        .padding(16)
        .background(AegisTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(AegisTheme.border) }
    }

    private func preview(width: CGFloat) -> some View {
        BankCardView(item: item)
            .frame(width: width, height: width / BankCardView.aspectRatio)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }

    private var centeredPreview: some View {
        BankCardView(item: item)
            .frame(maxWidth: 260)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("card.network")).aegisFont(size: 11, weight: .medium).foregroundStyle(AegisTheme.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8),
                                         count: typeSize.isAccessibilitySize ? 1 : 2), spacing: 8) {
                    ForEach(CardBrand.allCases) { brand in brandButton(brand) }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("card.fundingType")).aegisFont(size: 11, weight: .medium).foregroundStyle(AegisTheme.secondary)
                typeLayout {
                    ForEach(PaymentCardType.allCases) { type in
                        typeButton(type)
                    }
                }
                .padding(3).background(AegisTheme.inset, in: RoundedRectangle(cornerRadius: 11))
            }
        }
    }

    private func brandButton(_ brand: CardBrand) -> some View {
        let selected = item.cardBrand == brand
        return Button { item.cardBrand = brand } label: {
            HStack(spacing: 8) {
                Text(brand.title).aegisFont(size: 12, weight: selected ? .semibold : .medium)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1).minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(selected ? AegisTheme.teal : AegisTheme.secondary.opacity(0.5))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(selected ? AegisTheme.teal : AegisTheme.text)
            .padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, minHeight: 44)
            .background(selected ? AegisTheme.selected : AegisTheme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? AegisTheme.teal.opacity(0.45) : AegisTheme.border, lineWidth: 1)
            }.contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).accessibilityLabel(brand.title)
            .accessibilityAddTraits(selected ? [.isSelected] : []).accessibilityIdentifier("cardBrand-\(brand.rawValue)")
    }

    private var typeLayout: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 3)) : AnyLayout(HStackLayout(spacing: 3))
    }

    private func typeButton(_ type: PaymentCardType) -> some View {
        let selected = item.cardType == type
        return Button { item.cardType = type } label: {
            HStack(spacing: 6) {
                Image(systemName: type == .debit ? "banknote" : "creditcard").font(.system(size: 12, weight: .medium))
                Text(type.title).aegisFont(size: 12, weight: selected ? .semibold : .medium)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(selected ? AegisTheme.teal : AegisTheme.secondary)
            .padding(.horizontal, 8).padding(.vertical, 8).frame(maxWidth: .infinity, minHeight: 44)
            .background(selected ? AegisTheme.surface : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? AegisTheme.teal.opacity(0.2) : .clear)
            }.contentShape(RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityIdentifier("cardType-\(type.rawValue)")
    }
}

private struct CardArtwork: View {
    let brand: CardBrand?
    let palette: CardPalette
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                palette.gradient
                LinearGradient(colors: [.white.opacity(0.07), .clear, .black.opacity(0.13)], startPoint: .topLeading, endPoint: .bottomTrailing)
                CardArc(fill: true).fill(LinearGradient(colors: [palette.foil.opacity(0.05), palette.foil.opacity(0.29)],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing))
                CardArc().stroke(LinearGradient(colors: [palette.foil.opacity(0.05), palette.foil.opacity(0.8), .white.opacity(0.2)],
                                                startPoint: .leading, endPoint: .trailing), lineWidth: 0.55)
                watermark
                    .foregroundStyle(LinearGradient(colors: [palette.foil.opacity(0.26), palette.foil.opacity(0.04)],
                                                    startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: proxy.size.width * 0.51, height: proxy.size.height * 0.84)
                    .position(x: proxy.size.width * 0.83, y: proxy.size.height * 0.69)
            }
        }.accessibilityHidden(true)
    }

    @ViewBuilder private var watermark: some View {
        switch brand {
        case .unionPay:
            HStack(spacing: -15) {
                SlantedCardTile().opacity(0.7).frame(height: 92).offset(y: 12)
                SlantedCardTile().frame(height: 105)
            }.padding(.horizontal, 8)
        case .visa:
            Text("VISA").font(.system(size: 64, weight: .black)).italic().tracking(-3)
                .minimumScaleFactor(0.6).lineLimit(1)
        case .mastercard:
            HStack(spacing: -32) { Circle(); Circle().opacity(0.65) }
        case .americanExpress:
            CenturionMedallion().stroke(style: StrokeStyle(lineWidth: 0.8, lineCap: .round, lineJoin: .round))
        case nil:
            Image(systemName: "shield.lefthalf.filled").resizable().scaledToFit().padding(28)
        }
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
                    HStack(spacing: -6) {
                        ForEach([UInt32(0xD72035), 0x063E79, 0x086179], id: \.self) { hex in
                            SlantedCardTile().fill(CardPalette.color(hex))
                        }
                    }
                    VStack(spacing: 0) {
                        Text(L10n.text("card.brand.unionPay")).font(.system(size: compact ? 9 : 13, weight: .heavy)).italic()
                        if !compact { Text("UnionPay").font(.system(size: 10, weight: .bold)).italic() }
                    }.foregroundStyle(.white).minimumScaleFactor(0.6).lineLimit(1).padding(.horizontal, 3)
                }.frame(maxWidth: compact ? 36 : 70, maxHeight: compact ? 18 : 36)
            case .visa:
                Text("VISA").font(.system(size: compact ? 15 : 28, weight: .black)).italic().tracking(-1)
                    .foregroundStyle(ink).minimumScaleFactor(0.6).lineLimit(1)
            case .mastercard:
                VStack(spacing: 2) {
                    HStack(spacing: compact ? -7 : -9) {
                        Circle().fill(CardPalette.color(0xEB302C))
                        Circle().fill(CardPalette.color(0xF5A21A)).opacity(0.94)
                    }.frame(width: compact ? 31 : 47, height: compact ? 19 : 28)
                    if !compact { Text("mastercard").font(.system(size: 8, weight: .medium)).foregroundStyle(ink) }
                }
            case .americanExpress:
                if compact {
                    CenturionMedallion().stroke(ink, style: StrokeStyle(lineWidth: 0.8, lineCap: .round, lineJoin: .round))
                        .frame(width: 24, height: 24)
                } else {
                    VStack(spacing: 0) {
                        Text("AMERICAN")
                        Text("EXPRESS")
                    }.font(.system(size: 11, weight: .black)).tracking(-0.5).foregroundStyle(ink)
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

private struct SlantedCardTile: Shape {
    func path(in rect: CGRect) -> Path {
        let shape = Path(roundedRect: CGRect(x: 0, y: 0, width: rect.width * 0.76, height: rect.height), cornerRadius: rect.height * 0.12)
        return shape.applying(CGAffineTransform(a: 1, b: 0, c: -rect.width * 0.24 / max(1, rect.height), d: 1, tx: rect.width * 0.24, ty: 0))
    }
}

private struct CardArc: Shape {
    var fill = false
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        return Path { p in
            p.move(to: CGPoint(x: -w * 0.06, y: h * 0.79))
            p.addCurve(to: CGPoint(x: w * 0.75, y: h * 1.12),
                       control1: CGPoint(x: w * 0.26, y: h * 0.64),
                       control2: CGPoint(x: w * 0.55, y: h * 0.85))
            if fill {
                p.addLine(to: CGPoint(x: -w * 0.06, y: h * 1.12))
                p.closeSubpath()
            }
        }
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
        // Fine engraved rays and helmet ribs echo the relief on a metal card.
        for i in 0..<23 {
            let angle = Double(i) / 22 * Double.pi * 1.24 + Double.pi * 0.82
            p.move(to: v(0.5 + CGFloat(cos(angle)) * 0.35, 0.5 + CGFloat(sin(angle)) * 0.4))
            p.addLine(to: v(0.5 + CGFloat(cos(angle)) * 0.39, 0.5 + CGFloat(sin(angle)) * 0.445))
        }
        for i in 0..<7 {
            let y = CGFloat(i) * 0.014
            p.move(to: v(0.34, 0.38 + y))
            p.addQuadCurve(to: v(0.68, 0.34 + y), control: v(0.52, 0.23 + y))
        }
        p.move(to: v(0.29, 0.46)); p.addLine(to: v(0.24, 0.74)); p.addLine(to: v(0.35, 0.68))
        p.move(to: v(0.32, 0.49)); p.addLine(to: v(0.29, 0.7))
        p.addEllipse(in: CGRect(x: rect.minX + rect.width * 0.39, y: rect.minY + rect.height * 0.49,
                               width: rect.width * 0.055, height: rect.height * 0.095))
        for i in 0..<5 {
            let y = CGFloat(i) * 0.019
            p.move(to: v(0.47, 0.59 + y)); p.addLine(to: v(0.57, 0.67 + y))
        }
        return p
    }
}
