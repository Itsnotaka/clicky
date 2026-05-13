//
//  GlobalPushToTalkShortcutMonitor.swift
//  leanring-buddy
//
//  Captures push-to-talk keyboard shortcuts while makesomething is running in the
//  background. Uses a listen-only CGEvent tap so modifier-only shortcuts like
//  ctrl + option behave more like a real system-wide voice tool.
//

import AppKit
import Combine
import CoreGraphics
import Foundation

final class GlobalPushToTalkShortcutMonitor: ObservableObject {
    let shortcutTransitionPublisher = PassthroughSubject<BuddyPushToTalkShortcut.ShortcutTransition, Never>()

    private var globalEventTap: CFMachPort?
    private var globalEventTapRunLoopSource: CFRunLoopSource?
    private var globalNSEventMonitor: Any?
    private var localNSEventMonitor: Any?
    /// Mutated exclusively from the CGEvent tap callback, which runs on
    /// `CFRunLoopGetMain()` and therefore always executes on the main thread.
    /// Published so the overlay can hide immediately on key release without
    /// waiting for the async dictation state pipeline to catch up.
    @Published private(set) var isShortcutCurrentlyPressed = false

    deinit {
        stop()
    }

    func start() {
        // If the monitors are already running, don't restart them.
        // Restarting resets isShortcutCurrentlyPressed, which would kill
        // the waveform overlay mid-press when the permission poller calls
        // refreshAllPermissions -> start() every few seconds.
        guard globalEventTap == nil && globalNSEventMonitor == nil && localNSEventMonitor == nil else { return }

        if !startCGEventTap() {
            startNSEventMonitors()
        }
    }

    func stop() {
        isShortcutCurrentlyPressed = false

        if let globalEventTapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
            self.globalEventTapRunLoopSource = nil
        }

        if let globalEventTap {
            CFMachPortInvalidate(globalEventTap)
            self.globalEventTap = nil
        }

        if let globalNSEventMonitor {
            NSEvent.removeMonitor(globalNSEventMonitor)
            self.globalNSEventMonitor = nil
        }

        if let localNSEventMonitor {
            NSEvent.removeMonitor(localNSEventMonitor)
            self.localNSEventMonitor = nil
        }
    }

    private func startCGEventTap() -> Bool {
        let monitoredEventTypes: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let eventMask = monitoredEventTypes.reduce(CGEventMask(0)) { currentMask, eventType in
            currentMask | (CGEventMask(1) << eventType.rawValue)
        }

        let eventTapCallback: CGEventTapCallBack = { _, eventType, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let globalPushToTalkShortcutMonitor = Unmanaged<GlobalPushToTalkShortcutMonitor>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            return globalPushToTalkShortcutMonitor.handleGlobalEventTap(
                eventType: eventType,
                event: event
            )
        }

        guard let globalEventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("Global push-to-talk: could not create CGEvent tap; using AppKit monitors")
            return false
        }

        guard let globalEventTapRunLoopSource = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault,
            globalEventTap,
            0
        ) else {
            CFMachPortInvalidate(globalEventTap)
            print("Global push-to-talk: could not create event tap run loop source; using AppKit monitors")
            return false
        }

        self.globalEventTap = globalEventTap
        self.globalEventTapRunLoopSource = globalEventTapRunLoopSource

        CFRunLoopAddSource(CFRunLoopGetMain(), globalEventTapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: globalEventTap, enable: true)
        print("Global push-to-talk: CGEvent tap started")
        return true
    }

    private func startNSEventMonitors() {
        let eventMask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp]

        globalNSEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: eventMask) { [weak self] event in
            DispatchQueue.main.async {
                self?.handleNSEvent(event, source: "global-appkit")
            }
        }

        localNSEventMonitor = NSEvent.addLocalMonitorForEvents(matching: eventMask) { [weak self] event in
            self?.handleNSEvent(event, source: "local-appkit")
            return event
        }

        print("Global push-to-talk: AppKit monitor fallback started")
    }

    private func handleGlobalEventTap(
        eventType: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if eventType == .tapDisabledByTimeout || eventType == .tapDisabledByUserInput {
            if let globalEventTap {
                CGEvent.tapEnable(tap: globalEventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let shortcutTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: eventType,
            keyCode: eventKeyCode,
            modifierFlagsRawValue: event.flags.rawValue,
            wasShortcutPreviouslyPressed: isShortcutCurrentlyPressed
        )

        applyShortcutTransition(shortcutTransition, source: "cg-event-tap")
        return Unmanaged.passUnretained(event)
    }

    private func handleNSEvent(_ event: NSEvent, source: String) {
        let shortcutTransition = BuddyPushToTalkShortcut.shortcutTransition(
            for: event,
            wasShortcutPreviouslyPressed: isShortcutCurrentlyPressed
        )

        applyShortcutTransition(shortcutTransition, source: source)
    }

    private func applyShortcutTransition(
        _ shortcutTransition: BuddyPushToTalkShortcut.ShortcutTransition,
        source: String
    ) {
        switch shortcutTransition {
        case .none:
            break
        case .pressed:
            isShortcutCurrentlyPressed = true
            print("Push-to-talk pressed (\(source))")
            shortcutTransitionPublisher.send(.pressed)
        case .released:
            isShortcutCurrentlyPressed = false
            print("Push-to-talk released (\(source))")
            shortcutTransitionPublisher.send(.released)
        }
    }
}
