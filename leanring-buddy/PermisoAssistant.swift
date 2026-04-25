//
//  PermisoAssistant.swift
//  leanring-buddy
//
//  Lightweight System Settings permission guide using the zats/permiso API shape.
//

import AppKit
import Foundation
import SwiftUI

enum PermisoPanel: Equatable {
    case accessibility
    case screenRecording
    case automation(targetApplicationName: String?)

    var title: String {
        switch self {
        case .accessibility:
            return "Accessibility"
        case .screenRecording:
            return "Screen Recording"
        case .automation:
            return "Automation"
        }
    }

    var settingsIdentifier: String {
        switch self {
        case .accessibility:
            return "Privacy_Accessibility"
        case .screenRecording:
            return "Privacy_ScreenCapture"
        case .automation:
            return "Privacy_Automation"
        }
    }

    var settingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(settingsIdentifier)")!
    }

    var showsAppDragSource: Bool {
        switch self {
        case .accessibility, .screenRecording:
            return true
        case .automation:
            return false
        }
    }

    func guideText(appBundleName: String) -> String {
        switch self {
        case .accessibility, .screenRecording:
            return "Drag \(appBundleName) into the list above to allow \(title)."
        case .automation(let targetApplicationName):
            if let targetApplicationName {
                return "Turn on Clicky under \(targetApplicationName) to allow background browser actions."
            }
            return "Turn on Clicky under your browser to allow background browser actions."
        }
    }
}

@MainActor
final class PermisoAssistant {
    static let shared = PermisoAssistant()

    private var overlayController: CompanionPermissionGuideWindowController?
    private var trackingTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var didPresentCurrentOverlay = false

    func present(panel: PermisoPanel) {
        didPresentCurrentOverlay = false
        overlayController = CompanionPermissionGuideWindowController(panel: panel) { [weak self] in
            self?.dismiss()
        }

        openSettings(panel)
        startTracking()
    }

    func dismiss() {
        trackingTimer?.invalidate()
        trackingTimer = nil

        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }

        overlayController?.close()
        overlayController = nil
        didPresentCurrentOverlay = false
    }

    private func openSettings(_ panel: PermisoPanel) {
        NSWorkspace.shared.open(panel.settingsURL)
    }

    private func startTracking() {
        trackingTimer?.invalidate()
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPosition()
            }
        }

        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPosition()
            }
        }

        refreshPosition()
    }

    private func refreshPosition() {
        guard let snapshot = CompanionSystemSettingsWindowLocator.frontmostWindow() else {
            overlayController?.hide()
            return
        }

        if didPresentCurrentOverlay {
            overlayController?.updatePosition(settingsFrame: snapshot.frame, visibleFrame: snapshot.visibleFrame)
            return
        }

        overlayController?.present(settingsFrame: snapshot.frame, visibleFrame: snapshot.visibleFrame)
        didPresentCurrentOverlay = true
    }
}

private struct PermisoHostApp {
    let bundleURL: URL
    let icon: NSImage

    static func current(bundle: Bundle = .main) -> PermisoHostApp {
        let icon = NSWorkspace.shared.icon(forFile: bundle.bundleURL.path)
        icon.size = NSSize(width: 48, height: 48)
        return PermisoHostApp(bundleURL: bundle.bundleURL, icon: icon)
    }
}

private final class CompanionPermissionGuideWindowController: NSWindowController {
    private let windowSize = NSSize(width: 520, height: 116)
    private let guideWindow: NSWindow

    init(panel: PermisoPanel, onBack: @escaping () -> Void) {
        let guideWindow = CompanionPermissionGuidePanel(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.guideWindow = guideWindow
        super.init(window: guideWindow)
        configureWindow(guideWindow)
        guideWindow.contentView = NSHostingView(
            rootView: CompanionPermissionGuideView(
                panel: panel,
                hostApp: .current(),
                onBack: onBack
            )
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func close() {
        guideWindow.orderOut(nil)
        super.close()
    }

    func present(settingsFrame: CGRect, visibleFrame: CGRect) {
        guideWindow.alphaValue = 1
        guideWindow.setFrame(NSRect(origin: anchoredOrigin(for: settingsFrame, visibleFrame: visibleFrame), size: windowSize), display: false)
        guideWindow.orderFrontRegardless()
    }

    func updatePosition(settingsFrame: CGRect, visibleFrame: CGRect) {
        guideWindow.setFrameOrigin(anchoredOrigin(for: settingsFrame, visibleFrame: visibleFrame))
        guideWindow.orderFrontRegardless()
    }

    func hide() {
        guideWindow.orderOut(nil)
    }

    private func configureWindow(_ window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .statusBar
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.animationBehavior = .none
    }

    private func anchoredOrigin(for settingsFrame: CGRect, visibleFrame: CGRect) -> NSPoint {
        let sidebarWidth: CGFloat = 170
        let contentMinX = settingsFrame.minX + sidebarWidth
        let contentWidth = max(settingsFrame.width - sidebarWidth, windowSize.width)
        let preferredX = contentMinX + ((contentWidth - windowSize.width) / 2) - 8
        let preferredY = settingsFrame.minY + 14
        let minX = visibleFrame.minX + 8
        let maxX = visibleFrame.maxX - windowSize.width - 8
        let minY = visibleFrame.minY + 8
        let maxY = visibleFrame.maxY - windowSize.height - 8

        return NSPoint(
            x: min(max(preferredX, minX), maxX),
            y: min(max(preferredY, minY), maxY)
        )
    }
}

private final class CompanionPermissionGuidePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct CompanionPermissionGuideView: View {
    let panel: PermisoPanel
    let hostApp: PermisoHostApp
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .buttonStyle(.plain)
            .pointerCursor()

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color(red: 0.15, green: 0.54, blue: 0.98))

                    Text(panel.guideText(appBundleName: hostApp.bundleURL.lastPathComponent))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.84))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if panel.showsAppDragSource {
                    CompanionPermissionAppDragSource(hostApp: hostApp)
                        .frame(height: 40)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(width: 520, height: 116, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
    }
}

private struct CompanionPermissionAppDragSource: NSViewRepresentable {
    let hostApp: PermisoHostApp

    func makeNSView(context: Context) -> CompanionPermissionAppDragSourceView {
        CompanionPermissionAppDragSourceView(hostApp: hostApp)
    }

    func updateNSView(_ nsView: CompanionPermissionAppDragSourceView, context: Context) {}
}

private final class CompanionPermissionAppDragSourceView: NSView, NSPasteboardItemDataProvider, NSDraggingSource {
    private let hostApp: PermisoHostApp
    private let rowView = NSView()
    private let iconChrome = NSView()
    private let label = NSTextField(labelWithString: "")

    init(hostApp: PermisoHostApp) {
        self.hostApp = hostApp
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setup()
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setDataProvider(self, forTypes: [.fileURL])

        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(draggingFrame(), contents: draggingImage())

        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .fileURL else { return }
        item.setData(hostApp.bundleURL.dataRepresentation, forType: .fileURL)
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        rowView.isHidden = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        rowView.isHidden = false
    }

    private func setup() {
        wantsLayer = true

        rowView.wantsLayer = true
        rowView.layer?.cornerRadius = 7
        rowView.layer?.borderWidth = 1
        rowView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rowView)

        iconChrome.wantsLayer = true
        iconChrome.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
        iconChrome.layer?.cornerRadius = 6
        iconChrome.translatesAutoresizingMaskIntoConstraints = false
        rowView.addSubview(iconChrome)

        let iconView = NSImageView(image: hostApp.icon)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconChrome.addSubview(iconView)

        label.stringValue = hostApp.bundleURL.lastPathComponent
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = NSColor.labelColor.withAlphaComponent(0.82)
        label.translatesAutoresizingMaskIntoConstraints = false
        rowView.addSubview(label)

        NSLayoutConstraint.activate([
            rowView.leadingAnchor.constraint(equalTo: leadingAnchor),
            rowView.trailingAnchor.constraint(equalTo: trailingAnchor),
            rowView.topAnchor.constraint(equalTo: topAnchor),
            rowView.bottomAnchor.constraint(equalTo: bottomAnchor),
            rowView.heightAnchor.constraint(equalToConstant: 40),

            iconChrome.leadingAnchor.constraint(equalTo: rowView.leadingAnchor, constant: 9),
            iconChrome.centerYAnchor.constraint(equalTo: rowView.centerYAnchor),
            iconChrome.widthAnchor.constraint(equalToConstant: 25),
            iconChrome.heightAnchor.constraint(equalToConstant: 25),

            iconView.centerXAnchor.constraint(equalTo: iconChrome.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconChrome.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 21),
            iconView.heightAnchor.constraint(equalToConstant: 21),

            label.leadingAnchor.constraint(equalTo: iconChrome.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: rowView.trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: rowView.centerYAnchor)
        ])
    }

    private func updateAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isDark {
            rowView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
            rowView.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        } else {
            rowView.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.65).cgColor
            rowView.layer?.borderColor = NSColor(
                red: 0.87451,
                green: 0.866667,
                blue: 0.862745,
                alpha: 1
            ).cgColor
        }
    }

    private func draggingFrame() -> NSRect {
        convert(rowView.bounds, from: rowView)
    }

    private func draggingImage() -> NSImage {
        let image = NSImage(size: rowView.bounds.size)
        image.lockFocus()
        if let context = NSGraphicsContext.current {
            rowView.displayIgnoringOpacity(rowView.bounds, in: context)
        }
        image.unlockFocus()
        return image
    }
}

private struct CompanionSystemSettingsWindowSnapshot: Equatable {
    let frame: CGRect
    let visibleFrame: CGRect
}

private enum CompanionSystemSettingsWindowLocator {
    private static let bundleIdentifier = "com.apple.systempreferences"

    static func frontmostWindow() -> CompanionSystemSettingsWindowSnapshot? {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier else {
            return nil
        }

        guard let settingsApplication = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .max(by: { ($0.activationPolicy == .prohibited ? 0 : 1) < ($1.activationPolicy == .prohibited ? 0 : 1) }) else {
            return nil
        }

        guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], .zero) as? [[String: Any]] else {
            return nil
        }

        let windows = windowInfo.compactMap { info -> CompanionSystemSettingsWindowSnapshot? in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == settingsApplication.processIdentifier else {
                return nil
            }

            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else {
                return nil
            }

            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else {
                return nil
            }

            let cgFrame = CGRect(
                x: bounds["X"] ?? 0,
                y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0,
                height: bounds["Height"] ?? 0
            )
            let convertedGeometry = appKitGeometry(from: cgFrame)
            guard convertedGeometry.frame.width > 320, convertedGeometry.frame.height > 240 else {
                return nil
            }

            return CompanionSystemSettingsWindowSnapshot(
                frame: convertedGeometry.frame,
                visibleFrame: convertedGeometry.visibleFrame
            )
        }

        return windows.max {
            $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height
        }
    }

    private static func appKitGeometry(from cgFrame: CGRect) -> (frame: CGRect, visibleFrame: CGRect) {
        let screens = NSScreen.screens.compactMap { screen -> (frame: CGRect, visibleFrame: CGRect, cgBounds: CGRect)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }

            let displayID = CGDirectDisplayID(number.uint32Value)
            return (
                frame: screen.frame,
                visibleFrame: screen.visibleFrame,
                cgBounds: CGDisplayBounds(displayID)
            )
        }

        let matchedScreen = screens
            .filter { $0.cgBounds.intersects(cgFrame) }
            .max { lhs, rhs in
                lhs.cgBounds.intersection(cgFrame).width * lhs.cgBounds.intersection(cgFrame).height
                    < rhs.cgBounds.intersection(cgFrame).width * rhs.cgBounds.intersection(cgFrame).height
            }

        guard let matchedScreen else {
            let mainVisibleFrame = NSScreen.main?.visibleFrame ?? CGRect(origin: .zero, size: cgFrame.size)
            return (frame: cgFrame, visibleFrame: mainVisibleFrame)
        }

        let localX = cgFrame.minX - matchedScreen.cgBounds.minX
        let localY = cgFrame.minY - matchedScreen.cgBounds.minY
        let frame = CGRect(
            x: matchedScreen.frame.minX + localX,
            y: matchedScreen.frame.maxY - localY - cgFrame.height,
            width: cgFrame.width,
            height: cgFrame.height
        )

        return (frame: frame, visibleFrame: matchedScreen.visibleFrame)
    }
}
