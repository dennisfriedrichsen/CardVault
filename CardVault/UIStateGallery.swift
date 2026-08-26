#if DEBUG
import AppKit
import CardVaultCore
import ScreenCaptureKit
import SwiftUI

/// Writes one reference screenshot per `PrincipalUIState` from the real window.
///
/// This is a capture harness, not a demo mode: it exists so the state inventory
/// in `Docs/ui-state-audit.md` can be regenerated and diffed after any UI change
/// instead of being re-staged by hand with a card and two drives. It poses the
/// shipping `ContentView` in the shipping `WindowGroup`, so the toolbar, the
/// title bar, the materials and the system's own glass are the ones a user sees.
///
/// `#if DEBUG` throughout: a release build has no capture mode, no posed model,
/// and no way to reach either.
@MainActor
enum UIStateGallery {
    static let flag = "--capture-ui-states"

    static var isRequested: Bool { CommandLine.arguments.contains(flag) }

    /// CardVault runs under App Sandbox, so it cannot write into the repository
    /// even when asked to. Captures go to the container's own temporary
    /// directory and the path is printed for `Scripts/capture-ui-states.sh` to
    /// collect — the sandbox is part of the app being audited, so the harness
    /// lives inside it rather than being granted a hole.
    static var outputDirectory: URL {
        URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
            .appending(path: "cardvault-ui-states", directoryHint: .isDirectory)
    }

    /// Both appearances are captured because the legibility question the audit
    /// asks — does anything wash out against the glass — has a different answer
    /// in each.
    private static let appearances: [(name: String, appearance: NSAppearance.Name)] = [
        ("light", .aqua), ("dark", .darkAqua)
    ]

    static func run(model: AppModel) async {
        let directory = outputDirectory
        NSApp.activate(ignoringOtherApps: true)
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        guard await hasScreenRecordingAccess() else {
            FileHandle.standardError.write(Data(Self.screenRecordingHelp.utf8))
            exit(1)
        }

        var written = 0
        for (suffix, appearanceName) in appearances {
            NSApp.appearance = NSAppearance(named: appearanceName)
            for fixture in UIStateFixture.all {
                model.pose(fixture)
                await settle()
                guard let window = captureTarget() else {
                    FileHandle.standardError.write(Data("no window to capture for \(fixture.id)\n".utf8))
                    continue
                }
                let url = directory.appending(path: "\(fixture.id)-\(suffix).png")
                if await write(window: window, to: url) {
                    written += 1
                    print("captured \(url.lastPathComponent)")
                } else {
                    FileHandle.standardError.write(Data("failed to capture \(fixture.id)\n".utf8))
                }
            }
        }
        // The collecting script reads this line; keep the prefix stable.
        print("CARDVAULT_UI_STATES_DIR=\(directory.path)")
        print("wrote \(written) reference screenshots")
        NSApp.terminate(nil)
    }

    /// The main window, sheet and all. A sheet is captured in place rather than
    /// on its own, because whether it obscures the window behind it is part of
    /// what the reference set has to show.
    private static func captureTarget() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.styleMask.contains(.titled) }
    }

    /// Layout, the toolbar and the material blur all settle asynchronously, and
    /// a screenshot taken too early records a half-drawn window rather than a
    /// state. Yielding the main actor for a beat is what it takes in practice.
    private static func settle() async {
        try? await Task.sleep(for: .milliseconds(600))
        NSApp.windows.forEach { $0.displayIfNeeded() }
        try? await Task.sleep(for: .milliseconds(150))
    }

    /// Captures the whole window — title bar, toolbar and content — because the
    /// toolbar grouping and the glass behind it are part of what is being
    /// audited.
    ///
    /// The image has to come from the window server, which is why this run needs
    /// a screen-recording grant. SwiftUI's content is composited outside the
    /// app's own layers, so `cacheDisplay(in:to:)` and `CALayer.render(in:)`
    /// both return the chrome over an empty content area, and `ImageRenderer`
    /// draws `NavigationSplitView` and `List` as "not renderable" placeholders.
    /// A capture run that cannot photograph the real window fails rather than
    /// writing a picture of something the user will never see.
    private static func write(window: NSWindow, to url: URL) async -> Bool {
        let bounds = (window.contentView?.superview ?? window.contentView)?.bounds ?? .zero
        guard bounds.width > 1, bounds.height > 1, let image = await windowImage(window),
              let data = downscaledToPoints(NSBitmapImageRep(cgImage: image), size: bounds.size)?
                .representation(using: .png, properties: [:]) else { return false }
        do {
            try data.write(to: url)
            return true
        } catch {
            FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
            return false
        }
    }

    private static func windowImage(_ window: NSWindow) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) })
            else { return nil }
            let configuration = SCStreamConfiguration()
            configuration.width = Int(target.frame.width * window.backingScaleFactor)
            configuration.height = Int(target.frame.height * window.backingScaleFactor)
            configuration.showsCursor = false
            return try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: target),
                configuration: configuration)
        } catch {
            FileHandle.standardError.write(Data("capture failed: \(error.localizedDescription)\n".utf8))
            return nil
        }
    }

    /// Checked once, before any state is posed, so a run without the grant fails
    /// in a second with an instruction instead of writing 36 unusable files.
    private static func hasScreenRecordingAccess() async -> Bool {
        ((try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true))?
            .displays.isEmpty == false)
    }

    static let screenRecordingHelp = """
        CardVault cannot capture its own window without screen recording access.

        Grant it in System Settings > Privacy & Security > Screen & System Audio \
        Recording, adding the Debug build of CardVault.app, then run this again.

        (The window server owns the composited window. Capturing from inside the \
        app records the chrome over an empty content area, so no capture is \
        written rather than a misleading one.)

        """

    /// Retina backing stores make a 1080-point window a 2160-pixel file. The
    /// reference set is read by people, not pixel-peepers, and a repository does
    /// not need four times the bytes to answer "is this legible".
    private static func downscaledToPoints(_ rep: NSBitmapImageRep, size: CGSize) -> NSBitmapImageRep? {
        guard rep.pixelsWide > Int(size.width) else { return rep }
        guard let scaled = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return rep }
        scaled.size = size
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: scaled)
        NSGraphicsContext.current?.imageInterpolation = .high
        rep.draw(in: NSRect(origin: .zero, size: size))
        return scaled
    }
}

#endif
