#if DEBUG && os(macOS)
import AegisCore
import AppKit
import SwiftUI

/// Renders the actual SwiftUI components using synthetic data, without opening a vault.
enum CardDesignGallery {
    @MainActor static func renderIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--render-card-picker"), args.indices.contains(index + 1) {
            renderPicker(to: URL(fileURLWithPath: args[index + 1]), dark: args.contains("--dark"))
        }
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

    @MainActor private static func renderPicker(to destination: URL, dark: Bool) {
        NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let item = PreviewFixtures.cards.first { $0.cardBrand == .unionPay && $0.cardType == .debit }!
        let content = VStack(alignment: .leading, spacing: 28) {
            Text(L10n.text("card.pickerGalleryTitle")).font(.system(size: 24, weight: .semibold))
            HStack(alignment: .top, spacing: 32) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("macOS").font(.system(size: 13, weight: .medium)).foregroundStyle(AegisTheme.secondary)
                    CardAppearancePicker(item: .constant(item)).frame(width: 572)
                    sampleFields
                }.frame(width: 572)
                VStack(alignment: .leading, spacing: 16) {
                    Text("iPhone").font(.system(size: 13, weight: .medium)).foregroundStyle(AegisTheme.secondary)
                    CardAppearancePicker(item: .constant(item)).frame(width: 327)
                    sampleFields
                }.frame(width: 327)
            }
        }.padding(32).background(AegisTheme.background).foregroundStyle(AegisTheme.text)
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { exit(1) }
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: destination, options: .atomic)
            print("Rendered card picker: \(destination.path)")
            exit(0)
        } catch { exit(1) }
    }

    @MainActor private static var sampleFields: some View {
        VStack(alignment: .leading, spacing: 18) {
            AegisInput(title: L10n.text("field.cardholder"), icon: "person") {
                Text("AEGIS DEMO").frame(maxWidth: .infinity, alignment: .leading)
            }
            AegisInput(title: L10n.text("field.cardNumber"), icon: "creditcard") {
                Text("••••  ••••  ••••  4242").frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
#endif
