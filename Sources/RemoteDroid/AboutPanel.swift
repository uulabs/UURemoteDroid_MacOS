import AppKit

/// The standard About panel, with the scrcpy acknowledgement and links to the
/// licence texts shipped inside the app bundle.
enum AboutPanel {
    @MainActor
    static func show() {
        let body = NSFont.systemFont(ofSize: 11)
        let bold = NSFont.boldSystemFont(ofSize: 11)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 4

        func text(_ string: String, font: NSFont = body) -> NSAttributedString {
            NSAttributedString(string: string, attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ])
        }
        func link(_ string: String, _ url: URL) -> NSAttributedString {
            NSAttributedString(string: string, attributes: [
                .font: body,
                .link: url,
                .paragraphStyle: paragraph
            ])
        }

        let credits = NSMutableAttributedString()
        credits.append(text("Android mirroring and control by scrcpy\n", font: bold))
        credits.append(text("UU RemoteDroid bundles the unmodified scrcpy-server 5.0.1.\n"))
        credits.append(text("Copyright © 2018 Genymobile\nCopyright © 2018–2026 Romain Vimont\n"))
        credits.append(text("Licensed under the Apache License, Version 2.0.\n"))
        if let license = Bundle.main.url(forResource: "SCRCPY-LICENSE", withExtension: "txt") {
            credits.append(link("scrcpy licence", license))
            credits.append(text("  ·  "))
        }
        if let notices = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md") {
            credits.append(link("Third-party notices", notices))
            credits.append(text("  ·  "))
        }
        credits.append(link("scrcpy on GitHub", URL(string: "https://github.com/Genymobile/scrcpy")!))

        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "UU RemoteDroid",
            .credits: credits
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
}
