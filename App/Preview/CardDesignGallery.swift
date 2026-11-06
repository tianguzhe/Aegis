#if DEBUG && os(macOS)
import AegisCore
import AppKit
import SwiftUI

/// Renders the actual SwiftUI components using synthetic data, without opening a vault.
enum CardDesignGallery {
    @MainActor static func renderIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "--render-card-gallery"), args.indices.contains(index + 1) else { return }
        let destination = URL(fileURLWithPath: args[index + 1])
        let content = VStack(alignment: .leading, spacing: 34) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Aegis").font(.system(size: 40, weight: .medium, design: .serif))
                    Text(L10n.text("card.galleryTitle")).font(.system(size: 18, weight: .medium))
                }
                Spacer()
                Text(L10n.text("card.gallerySubtitle")).font(.system(size: 12)).foregroundStyle(AegisTheme.secondary)
            }
            Grid(horizontalSpacing: 28, verticalSpacing: 28) {
                ForEach(CardBrand.allCases) { brand in
                    GridRow(alignment: .top) {
                        ForEach(PaymentCardType.allCases) { type in
                            let item = PreviewFixtures.cards.first { $0.cardBrand == brand && $0.cardType == type }!
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text(item.cardDescription).font(.system(size: 13, weight: .semibold))
                                    Spacer()
                                    Text(L10n.text(CardPalette(brand: brand, type: type).nameKey))
                                        .font(.system(size: 12)).foregroundStyle(AegisTheme.secondary)
                                }
                                BankCardView(item: item)
                            }.frame(width: 440)
                        }
                    }
                }
            }
        }.foregroundStyle(AegisTheme.text).padding(40).background(AegisTheme.background)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        do {
            guard let cgImage = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
                exit(1)
            }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: destination, options: .atomic)
            print("Rendered card gallery: \(destination.path)")
            exit(0)
        } catch {
            fputs("Could not render card gallery: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
#endif
