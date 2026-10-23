//
//  OpenAppBox.swift
//  PathDiff
//

import AppKit
import SwiftUI

/// PathDiff is one app in the OpenAppBox family. PathDiff's own name and icon always lead;
/// the parent brand only appears as a quiet endorsement (About panel, Help, start screen, footers).
nonisolated enum OpenAppBox {
    static let name = "OpenAppBox"
    static let endorsement = String(localized: "An OpenAppBox App")
    static let tagline = String(localized: "Open source apps for everyone")
    static let website = URL(string: "https://openappbox.com")!
    static let websiteLabel = "openappbox.com"

    /// Full-color mark, for places with room to show the brand (Help).
    static let iconImageName = "OpenAppBoxIcon"
    /// Single-color template mark, tinted like text, for small inline endorsements.
    static let markImageName = "OpenAppBoxMark"

    /// Shows the standard About panel with the OpenAppBox endorsement as its credits.
    @MainActor
    static func showAboutPanel() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let credits = NSMutableAttributedString(
            string: "\(endorsement)\n\(tagline).\n",
            attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph]
        )
        credits.append(NSAttributedString(
            string: websiteLabel,
            attributes: [.font: small, .link: website, .paragraphStyle: paragraph]
        ))
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApplication.shared.activate()
    }
}

/// A small “An OpenAppBox App” line with the single-color mark, linking to openappbox.com.
struct OpenAppBoxBadge: View {
    var font: Font = .caption

    var body: some View {
        Link(destination: OpenAppBox.website) {
            HStack(spacing: 5) {
                Image(OpenAppBox.markImageName)
                    .resizable()
                    .renderingMode(.template)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 12, height: 12)
                Text(OpenAppBox.endorsement)
            }
            .font(font)
            .foregroundStyle(.tertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Visit \(OpenAppBox.websiteLabel)")
        .accessibilityLabel(String(localized: "An OpenAppBox App. Visit \(OpenAppBox.websiteLabel)"))
    }
}
