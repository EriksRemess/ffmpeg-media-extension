import AppKit
import MediaToolbox
import VideoToolbox

@MainActor
final class LinkButton: NSButton {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!

    @objc private func quitApplication(_ sender: Any?) {
        NSApp.terminate(sender)
    }

    @objc private func openRepository(_ sender: Any?) {
        guard let button = sender as? NSButton,
              let address = button.identifier?.rawValue,
              let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let applicationMenuItem = NSMenuItem()
        mainMenu.addItem(applicationMenuItem)

        let applicationMenu = NSMenu(title: "FFmpeg Media Extension")
        applicationMenuItem.submenu = applicationMenu
        applicationMenu.addItem(withTitle: "About FFmpeg Media Extension",
                                action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                                keyEquivalent: "")
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Hide FFmpeg Media Extension",
                                action: #selector(NSApplication.hide(_:)),
                                keyEquivalent: "h")

        let hideOthers = NSMenuItem(title: "Hide Others",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        applicationMenu.addItem(hideOthers)
        applicationMenu.addItem(withTitle: "Show All",
                                action: #selector(NSApplication.unhideAllApplications(_:)),
                                keyEquivalent: "")
        applicationMenu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit FFmpeg Media Extension",
                                  action: #selector(quitApplication(_:)),
                                  keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        applicationMenu.addItem(quitItem)
        NSApp.mainMenu = mainMenu
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }

        MTRegisterProfessionalVideoWorkflowFormatReaders()
        VTRegisterProfessionalVideoWorkflowVideoDecoders()
        installMainMenu()

        let frame = NSRect(x: 0, y: 0, width: 560, height: 300)
        window = NSWindow(contentRect: frame,
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered,
                          defer: false)
        window.title = "FFmpeg Media Extension"
        window.center()

        let label = NSTextField(wrappingLabelWithString: """
        FFmpeg Media Extension

        The embedded MediaExtensions add Matroska and WebM container support plus FFmpeg VP9, AV1, and MPEG-2 video decoding to participating AVFoundation applications, including QuickTime Player.

        This is an independent, unofficial MediaExtension. It is not an FFmpeg product and is not affiliated with or endorsed by the FFmpeg project.

        Enable both extensions in System Settings → General → Login Items & Extensions, then reopen QuickTime Player.
        """)
        label.font = .systemFont(ofSize: 14)
        label.frame = NSRect(x: 30, y: 55, width: 500, height: 225)
        window.contentView?.addSubview(label)

        func makeGitHubLink(title: String, address: String, toolTip: String) -> (NSStackView, NSButton) {
            let linkLabel = NSTextField(labelWithString: title)
            linkLabel.font = .systemFont(ofSize: 13, weight: .medium)
            linkLabel.textColor = .labelColor

            let linkIcon = NSImageView()
            if let iconURL = Bundle.main.url(forResource: "GitHub_Invertocat_Black", withExtension: "svg"),
               let icon = NSImage(contentsOf: iconURL) {
                icon.size = NSSize(width: 18, height: 18)
                icon.isTemplate = true
                linkIcon.image = icon
                linkIcon.imageScaling = .scaleProportionallyDown
                linkIcon.contentTintColor = .labelColor
            }
            linkIcon.widthAnchor.constraint(equalToConstant: 18).isActive = true
            linkIcon.heightAnchor.constraint(equalToConstant: 18).isActive = true

            let linkRow = NSStackView(views: [linkIcon, linkLabel])
            linkRow.orientation = .horizontal
            linkRow.alignment = .centerY
            linkRow.spacing = 8

            let hitTarget = LinkButton()
            hitTarget.title = ""
            hitTarget.isBordered = false
            hitTarget.isTransparent = true
            hitTarget.focusRingType = .none
            hitTarget.translatesAutoresizingMaskIntoConstraints = false
            hitTarget.target = self
            hitTarget.action = #selector(openRepository(_:))
            hitTarget.identifier = NSUserInterfaceItemIdentifier(address)
            hitTarget.toolTip = toolTip
            hitTarget.setAccessibilityLabel(title)
            return (linkRow, hitTarget)
        }

        let projectLink = makeGitHubLink(
            title: "EriksRemess/ffmpeg-media-extension",
            address: "https://github.com/EriksRemess/ffmpeg-media-extension",
            toolTip: "Open the project on GitHub"
        )
        let ffmpegLink = makeGitHubLink(
            title: "FFmpeg/FFmpeg",
            address: "https://github.com/FFmpeg/FFmpeg",
            toolTip: "Open FFmpeg on GitHub"
        )
        let repositoryRow = NSStackView(views: [projectLink.0, ffmpegLink.0])
        repositoryRow.orientation = .horizontal
        repositoryRow.alignment = .centerY
        repositoryRow.spacing = 24
        repositoryRow.translatesAutoresizingMaskIntoConstraints = false

        if let contentView = window.contentView {
            contentView.addSubview(repositoryRow)
            contentView.addSubview(projectLink.1)
            contentView.addSubview(ffmpegLink.1)
            NSLayoutConstraint.activate([
                repositoryRow.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                repositoryRow.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -38.5),
                projectLink.1.leadingAnchor.constraint(equalTo: projectLink.0.leadingAnchor, constant: -5),
                projectLink.1.trailingAnchor.constraint(equalTo: projectLink.0.trailingAnchor, constant: 5),
                projectLink.1.topAnchor.constraint(equalTo: projectLink.0.topAnchor, constant: -5),
                projectLink.1.bottomAnchor.constraint(equalTo: projectLink.0.bottomAnchor, constant: 5),
                ffmpegLink.1.leadingAnchor.constraint(equalTo: ffmpegLink.0.leadingAnchor, constant: -5),
                ffmpegLink.1.trailingAnchor.constraint(equalTo: ffmpegLink.0.trailingAnchor, constant: 5),
                ffmpegLink.1.topAnchor.constraint(equalTo: ffmpegLink.0.topAnchor, constant: -5),
                ffmpegLink.1.bottomAnchor.constraint(equalTo: ffmpegLink.0.bottomAnchor, constant: 5),
            ])
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
