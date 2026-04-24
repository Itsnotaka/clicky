//
//  DesignSystem.swift
//  leanring-buddy
//

import SwiftUI
import AppKit

enum DS {

    enum Colors {

        static let background = Color(lightHex: "#F5F2EC", darkHex: "#101211")
        static let surface1 = Color(lightHex: "#FFFCF6", darkHex: "#171918")
        static let surface2 = Color(lightHex: "#F0EDE6", darkHex: "#202221")
        static let surface3 = Color(lightHex: "#E7E2D9", darkHex: "#272A29")
        static let surface4 = Color(lightHex: "#DDD7CD", darkHex: "#2E3130")

        static let borderSubtle = Color(lightHex: "#D4CEC3", darkHex: "#373B39")
        static let borderStrong = Color(lightHex: "#B9B0A3", darkHex: "#444947")

        static let textPrimary = Color(lightHex: "#1E211F", darkHex: "#ECEEED")
        static let textSecondary = Color(lightHex: "#4D5651", darkHex: "#ADB5B2")
        static let textTertiary = Color(lightHex: "#737B76", darkHex: "#6B736F")
        static let textOnAccent: Color = .white

        static let accent = Color(displayP3FromSRGBHex: "#FF4700")
        static let accentHover = Color(displayP3FromSRGBHex: "#E03E00")
        static let accentText = Color(displayP3FromSRGBHex: "#FF8F66")
        static let accentSubtle = accent.opacity(0.10)

        static let destructive = Color(hex: "#E5484D")
        static let destructiveHover = Color(hex: "#F2555A")
        static let destructiveText = Color(hex: "#FF6369")

        static let success = Color(hex: "#34D399")

        static let warning = Color(hex: "#FFB224")
        static let warningText = Color(hex: "#F1A10D")

        static let info = Color(hex: "#70B8FF")
        static let codeText = Color(hex: "#9DC2FF")

        static let overlayCursor = Color(displayP3FromSRGBHex: "#FF5C1A")

        static let floatingGradientPurple = Color(hex: "#8F46EB")
        static let floatingGradientPink = Color(hex: "#E84D9E")
        static let floatingGradientOrange = Color(hex: "#FF8C33")

        static let helpChatUserBubble = Color(displayP3FromSRGBHex: "#9A3412")
        static let helpChatUserBubbleHover = Color(displayP3FromSRGBHex: "#C2410C")

        static let helpChatBackdrop = Color(lightHex: "#ECE7DD", darkHex: "#212121")

        static var disabledBackground: Color {
            textPrimary.opacity(0.12)
        }

        static var disabledText: Color {
            textPrimary.opacity(0.38)
        }
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let xxxl: CGFloat = 32
    }

    enum CornerRadius {
        static let small: CGFloat = 6
        static let medium: CGFloat = 8
        static let large: CGFloat = 10
        static let extraLarge: CGFloat = 12
        static let pill: CGFloat = .infinity
    }

    enum Animation {
        static let fast: Double = 0.15
        static let normal: Double = 0.25
        static let slow: Double = 0.4
    }

    enum StateLayer {
        static let hover: Double = 0.08
        static let focus: Double = 0.12
        static let pressed: Double = 0.12
        static let dragged: Double = 0.16
    }
}

struct DSPrimaryButtonStyle: ButtonStyle {
    var isFullWidth: Bool = true

    @State private var isHovered = false

    @State private var isHoverScaleExpanded = false
    @State private var isHoverGlowActive = false
    @State private var isGlowBreathingIn = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(DS.Colors.textOnAccent)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .padding(.vertical, 14)
            .padding(.horizontal, isFullWidth ? 0 : 20)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .shadow(
                color: DS.Colors.accent.opacity(
                    isHoverGlowActive ? (isGlowBreathingIn ? 0.32 : 0.18) : 0
                ),
                radius: isHoverGlowActive ? (isGlowBreathingIn ? 16 : 10) : 0
            )
            .scaleEffect(configuration.isPressed ? 0.97 : (isHoverScaleExpanded ? 1.03 : 1.0))
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) {
                    isHovered = hovering
                }

                withAnimation(.easeInOut(duration: hovering ? 0.6 : 0.3)) {
                    isHoverScaleExpanded = hovering
                }

                withAnimation(.easeInOut(duration: hovering ? 0.6 : 0.3)) {
                    isHoverGlowActive = hovering
                }

                if hovering {
                    withAnimation(
                        .easeInOut(duration: 2.5)
                        .repeatForever(autoreverses: true)
                    ) {
                        isGlowBreathingIn = true
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.3)) {
                        isGlowBreathingIn = false
                    }
                }

                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.accentHover.blendedWithWhite(fraction: DS.StateLayer.pressed)
        } else if isHovered {
            return DS.Colors.accentHover
        } else {
            return DS.Colors.accent
        }
    }
}

struct DSSecondaryButtonStyle: ButtonStyle {
    var isFullWidth: Bool = true

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(DS.Colors.textPrimary)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .padding(.vertical, 12)
            .padding(.horizontal, isFullWidth ? 0 : 16)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.surface4
        } else if isHovered {
            return DS.Colors.surface3
        } else {
            return DS.Colors.surface2
        }
    }
}

struct DSTertiaryButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(
                configuration.isPressed
                    ? DS.Colors.accentHover
                    : isHovered
                        ? DS.Colors.accentText
                        : DS.Colors.textSecondary
            )
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.surface3
        } else if isHovered {
            return DS.Colors.surface2
        } else {
            return Color.clear
        }
    }
}

struct DSTextButtonStyle: ButtonStyle {
    var fontSize: CGFloat = 14

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .medium))
            .foregroundColor(
                configuration.isPressed
                    ? DS.Colors.textPrimary
                    : isHovered
                        ? DS.Colors.textPrimary
                        : DS.Colors.textTertiary
            )
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }
}

struct DSOutlinedButtonStyle: ButtonStyle {
    var isFullWidth: Bool = true

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(DS.Colors.textPrimary)
            .frame(maxWidth: isFullWidth ? .infinity : nil)
            .padding(.vertical, 12)
            .padding(.horizontal, isFullWidth ? 0 : 16)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                Capsule()
                    .stroke(
                        borderColor(isPressed: configuration.isPressed),
                        lineWidth: 1
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.surface3
        } else if isHovered {
            return DS.Colors.surface2
        } else {
            return DS.Colors.surface1
        }
    }

    private func borderColor(isPressed: Bool) -> Color {
        if isPressed || isHovered {
            return DS.Colors.borderStrong
        } else {
            return DS.Colors.borderSubtle
        }
    }
}

struct DSDestructiveButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(
                isHovered || configuration.isPressed
                    ? .white
                    : DS.Colors.destructiveText
            )
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .background(
                Capsule()
                    .fill(buttonBackgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                Capsule()
                    .stroke(
                        borderColor(isPressed: configuration.isPressed),
                        lineWidth: 1
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
    }

    private func buttonBackgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return DS.Colors.destructive.opacity(0.40)
        } else if isHovered {
            return DS.Colors.destructive.opacity(0.30)
        } else {
            return DS.Colors.destructive.opacity(0.10)
        }
    }

    private func borderColor(isPressed: Bool) -> Color {
        if isPressed || isHovered {
            return DS.Colors.destructive.opacity(0.40)
        } else {
            return DS.Colors.destructive.opacity(0.15)
        }
    }
}

struct DSIconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var isDestructiveOnHover: Bool = false
    var tooltipText: String? = nil

    var tooltipAlignment: Alignment = .center

    @State private var isHovered = false
    @State private var isTooltipVisible = false
    @State private var tooltipShowWorkItem: DispatchWorkItem? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.43, weight: .semibold))
            .foregroundColor(iconColor(isPressed: configuration.isPressed))
            .frame(width: size, height: size)
            .background(
                Circle()
                    .fill(circleBackgroundColor(isPressed: configuration.isPressed))
            )
            .overlay(
                Circle()
                    .stroke(circleBorderColor(isPressed: configuration.isPressed), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .contentShape(Circle())
            .overlay(PointerCursorView())
            .onHover { hovering in
                isHovered = hovering
                tooltipShowWorkItem?.cancel()
                if hovering {
                    let workItem = DispatchWorkItem {
                        withAnimation(.easeOut(duration: 0.15)) {
                            isTooltipVisible = true
                        }
                    }
                    tooltipShowWorkItem = workItem
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: workItem)
                } else {
                    withAnimation(.easeOut(duration: 0.1)) {
                        isTooltipVisible = false
                    }
                }
            }
            .overlay(
                Group {
                    if isTooltipVisible, let text = tooltipText, !text.isEmpty {
                        Text(text)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(DS.Colors.surface3.opacity(0.85))
                            )
                            .overlay(
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.white.opacity(0.20), lineWidth: 0.8)

                                    RoundedRectangle(cornerRadius: 6)
                                        .trim(from: 0, to: 0.5)
                                        .stroke(
                                            LinearGradient(
                                                colors: [
                                                    Color.white.opacity(0.10),
                                                    Color.white.opacity(0.02)
                                                ],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            ),
                                            lineWidth: 0.8
                                        )
                                }
                            )
                            .shadow(color: Color.black.opacity(0.42), radius: 14, x: 0, y: 8)
                            .shadow(color: Color.black.opacity(0.26), radius: 4, x: 0, y: 2)
                            .fixedSize()
                            .offset(y: -(size / 2 + 20))
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                },
                alignment: tooltipAlignment
            )
    }

    private func iconColor(isPressed: Bool) -> Color {
        if isDestructiveOnHover && (isHovered || isPressed) {
            return .white
        }
        if isPressed {
            return DS.Colors.textPrimary
        } else if isHovered {
            return DS.Colors.textPrimary
        } else {
            return DS.Colors.textSecondary
        }
    }

    private func circleBackgroundColor(isPressed: Bool) -> Color {
        if isDestructiveOnHover {
            if isPressed {
                return DS.Colors.destructive.opacity(0.40)
            } else if isHovered {
                return DS.Colors.destructive.opacity(0.30)
            } else {
                return DS.Colors.surface2
            }
        }
        if isPressed {
            return DS.Colors.surface4
        } else if isHovered {
            return DS.Colors.surface3
        } else {
            return DS.Colors.surface2
        }
    }

    private func circleBorderColor(isPressed: Bool) -> Color {
        if isDestructiveOnHover && (isHovered || isPressed) {
            return DS.Colors.destructive.opacity(0.30)
        }
        if isPressed || isHovered {
            return DS.Colors.borderStrong
        } else {
            return DS.Colors.borderSubtle.opacity(0.5)
        }
    }
}

extension View {
    func dsPrimaryButtonStyle(isFullWidth: Bool = true) -> some View {
        self.buttonStyle(DSPrimaryButtonStyle(isFullWidth: isFullWidth))
    }

    func dsSecondaryButtonStyle(isFullWidth: Bool = true) -> some View {
        self.buttonStyle(DSSecondaryButtonStyle(isFullWidth: isFullWidth))
    }

    func dsTertiaryButtonStyle() -> some View {
        self.buttonStyle(DSTertiaryButtonStyle())
    }

    func dsTextButtonStyle(fontSize: CGFloat = 14) -> some View {
        self.buttonStyle(DSTextButtonStyle(fontSize: fontSize))
    }

    func dsOutlinedButtonStyle(isFullWidth: Bool = true) -> some View {
        self.buttonStyle(DSOutlinedButtonStyle(isFullWidth: isFullWidth))
    }

    func dsDestructiveButtonStyle() -> some View {
        self.buttonStyle(DSDestructiveButtonStyle())
    }

    func dsIconButtonStyle(size: CGFloat = 28, isDestructiveOnHover: Bool = false, tooltip: String? = nil, tooltipAlignment: Alignment = .center) -> some View {
        self.buttonStyle(DSIconButtonStyle(size: size, isDestructiveOnHover: isDestructiveOnHover, tooltipText: tooltip, tooltipAlignment: tooltipAlignment))
    }

    func pointerCursor(isEnabled: Bool = true) -> some View {
        self.overlay {
            if isEnabled {
                PointerCursorView()
            }
        }
    }
}

enum BuddyComposerVisualStyle {
    static let waveformLeadingColor = Color(displayP3FromSRGBHex: "#FFF5F0")
    static let waveformTrailingColor = Color(displayP3FromSRGBHex: "#FFB088")
    static let waveformGlowColor = Color(displayP3FromSRGBHex: "#FFC9A3")
}

private class PointerCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

private struct PointerCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        return PointerCursorNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

private class IBeamCursorNSView: NSView {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

struct IBeamCursorView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        return IBeamCursorNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

private struct NativeTooltipView: NSViewRepresentable {
    let tooltip: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.toolTip = tooltip
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.toolTip = tooltip
    }
}

extension View {
    func nativeTooltip(_ text: String?) -> some View {
        if let text = text, !text.isEmpty {
            return AnyView(self.overlay(NativeTooltipView(tooltip: text)))
        } else {
            return AnyView(self)
        }
    }
}

extension Color {
    init(hex: String) {
        let hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        var rgbValue: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgbValue)

        let red = Double((rgbValue & 0xFF0000) >> 16) / 255.0
        let green = Double((rgbValue & 0x00FF00) >> 8) / 255.0
        let blue = Double(rgbValue & 0x0000FF) / 255.0

        self.init(red: red, green: green, blue: blue)
    }

    /// sRGB `#RRGGBB` converted to Display P3 for correct tagging on wide-gamut displays (same chromaticity as the hex, not a more saturated P3-only orange).
    init(displayP3FromSRGBHex hex: String, alpha: CGFloat = 1.0) {
        let srgb = NSColor(hex: hex).usingColorSpace(.sRGB) ?? NSColor(hex: hex)
        let displayP3 = srgb.usingColorSpace(.displayP3) ?? srgb
        self.init(nsColor: displayP3.withAlphaComponent(alpha))
    }

    init(lightHex: String, darkHex: String) {
        self.init(
            NSColor(name: nil) { appearance in
                let bestMatchedAppearance = appearance.bestMatch(from: [.aqua, .darkAqua])
                let hex = bestMatchedAppearance == .darkAqua ? darkHex : lightHex
                return NSColor(hex: hex)
            }
        )
    }

    func blendedWithWhite(fraction: Double) -> Color {
        guard let nsColor = NSColor(self).usingColorSpace(.sRGB) else { return self }

        let red = nsColor.redComponent + (1.0 - nsColor.redComponent) * fraction
        let green = nsColor.greenComponent + (1.0 - nsColor.greenComponent) * fraction
        let blue = nsColor.blueComponent + (1.0 - nsColor.blueComponent) * fraction

        return Color(red: red, green: green, blue: blue)
    }
}

extension NSColor {
    convenience init(hex: String) {
        let hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        var rgbValue: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgbValue)

        let red = CGFloat((rgbValue & 0xFF0000) >> 16) / 255.0
        let green = CGFloat((rgbValue & 0x00FF00) >> 8) / 255.0
        let blue = CGFloat(rgbValue & 0x0000FF) / 255.0

        self.init(srgbRed: red, green: green, blue: blue, alpha: 1.0)
    }
}
