import AppKit
import Combine
import SwiftUI

// MARK: - Bubble geometry (published so SwiftUI redraws the tail on reposition)

final class BubbleGeometry: ObservableObject {
    static let tailWidth: CGFloat = 18
    static let tailHeight: CGFloat = 9
    static let panelWidth: CGFloat = 360
    static let defaultHeight: CGFloat = 160 + BubbleGeometry.tailHeight

    // Horizontal position of the tail's apex, in the panel's own coordinate space.
    @Published var tailX: CGFloat = BubbleGeometry.panelWidth - 30
}

// MARK: - Panel

final class OverlayPanel: NSPanel {
    private let correctionEngine: CorrectionEngine
    private let onAccept: () -> Void
    private let onDismiss: () -> Void
    private let geometry = BubbleGeometry()
    private let hostingView: NSHostingView<OverlayContentView>
    private var cancellables = Set<AnyCancellable>()

    // Last status-item frame we were positioned against, and the horizontal
    // origin computed from it. Retained so we can re-derive the panel's frame
    // whenever its height changes without needing a fresh position() call.
    private var anchorFrame: CGRect?
    private var originX: CGFloat = 0

    init(correctionEngine: CorrectionEngine, onAccept: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.correctionEngine = correctionEngine
        self.onAccept = onAccept
        self.onDismiss = onDismiss

        let content = OverlayContentView(
            correctionEngine: correctionEngine,
            geometry: geometry,
            onAccept: onAccept,
            onDismiss: onDismiss
        )
        let hostingView = NSHostingView(rootView: content)
        self.hostingView = hostingView

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: BubbleGeometry.panelWidth, height: BubbleGeometry.defaultHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hasShadow = true
        isMovable = false

        // NSHostingView defaults to deriving Auto Layout min/max/intrinsic-size
        // constraints from its SwiftUI content and applying them to the window's
        // contentMinSize/contentMaxSize — which fights and overrides our manual
        // setFrame() calls in relayout(). Disable that so we're fully in control.
        // (We also can't reliably read the content's size back out through SwiftUI —
        // neither PreferenceKey propagation nor intrinsicContentSize/fittingSize behave
        // predictably for this dynamically-streaming, AppKit-hosted content — so
        // desiredHeight below measures the text directly with AppKit's own APIs instead.)
        hostingView.sizingOptions = []
        contentView = hostingView

        // Re-measure and resize whenever the content that affects height changes.
        // (SwiftUI PreferenceKey-based size reporting doesn't reliably propagate
        // out of this AppKit-hosted view, so we pull the size directly instead.)
        correctionEngine.$correctionText
            .combineLatest(correctionEngine.$state)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.relayout() }
            .store(in: &cancellables)

        // Also relayout when the user toggles resize mode so an open bubble
        // immediately snaps to the correct size without waiting for the next token.
        SettingsStore.shared.$resizeBubbleToFitText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.relayout() }
            .store(in: &cancellables)
    }

    /// Positions the bubble directly below the menu bar status item, with its
    /// tail pointing up at the icon. `statusItemFrame` is in AppKit screen
    /// coordinates (origin bottom-left), as returned by the status item's button window.
    func position(belowStatusItem statusItemFrame: CGRect) {
        let panelWidth = BubbleGeometry.panelWidth
        let tailInsetFromRight: CGFloat = 30
        let iconMidX = statusItemFrame.midX

        var computedOriginX = iconMidX - (panelWidth - tailInsetFromRight)
        var tailX = panelWidth - tailInsetFromRight

        if let screen = screenContaining(statusItemFrame) ?? NSScreen.main {
            let visibleFrame = screen.visibleFrame
            let minX = visibleFrame.minX + 8
            let maxX = visibleFrame.maxX - panelWidth - 8
            if computedOriginX > maxX {
                tailX += computedOriginX - maxX
                computedOriginX = maxX
            }
            if computedOriginX < minX {
                tailX -= minX - computedOriginX
                computedOriginX = minX
            }
            // Keep the tail apex from sliding past the bubble's rounded corners.
            tailX = min(max(tailX, 24), panelWidth - 24)
        }

        geometry.tailX = tailX
        anchorFrame = statusItemFrame
        originX = computedOriginX
        relayout()
    }

    /// Recomputes the panel's frame from the last known anchor, keeping the top
    /// edge (the tail apex, next to the status icon) fixed while the height
    /// tracks either the static default or the live content height.
    /// Early-returns when the frame hasn't changed to avoid redundant
    /// `setFrame(display:)` calls on every streamed token.
    private func relayout() {
        guard let anchorFrame else { return }
        let height = desiredHeight
        let originY = anchorFrame.minY - height
        let newFrame = NSRect(x: originX, y: originY, width: BubbleGeometry.panelWidth, height: height)
        guard newFrame != frame else { return }
        setFrame(newFrame, display: true)
    }

    // MARK: - Layout constants
    // These are shared between the AppKit panel (measurement) and the SwiftUI view
    // (padding/font), so the two can never silently diverge.

    /// Horizontal padding on each side of the correction text.
    static let textHPadding: CGFloat = 12
    /// Vertical padding on each side of the correction text.
    static let textVPadding: CGFloat = 8
    /// Font size used for the correction text.
    static let textFontSize: CGFloat = 13
    /// Minimum height of the text area.
    static let minTextAreaHeight: CGFloat = 40
    /// Ceiling on how tall the text area is allowed to grow before it scrolls.
    static let maxTextAreaHeight: CGFloat = 320

    /// The fixed, non-text-driven "chrome" height (header + divider + tail + outer
    /// padding) that surrounds the text area — everything `defaultHeight` budgets for
    /// besides the default fixed text area.
    private static let chromeHeight: CGFloat = BubbleGeometry.defaultHeight - 100

    // MARK: - Text measurement

    /// Measures how tall the text area should be for the given string using the same
    /// font, padding, and clamp used by the SwiftUI view. Single source of truth —
    /// both `desiredHeight` and `OverlayContentView.textAreaHeight` call this.
    static func measuredTextAreaHeight(for text: String) -> CGFloat {
        let t = text.isEmpty ? " " : text
        let width = BubbleGeometry.panelWidth - textHPadding * 2
        let bounds = (t as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: textFontSize)]
        )
        return min(max(ceil(bounds.height) + textVPadding * 2, minTextAreaHeight), maxTextAreaHeight)
    }

    private var desiredHeight: CGFloat {
        guard SettingsStore.shared.resizeBubbleToFitText else {
            return BubbleGeometry.defaultHeight
        }

        let textAreaHeight = Self.measuredTextAreaHeight(for: correctionEngine.correctionText)

        var extra: CGFloat = 0
        if correctionEngine.state == .finished, !correctionEngine.correctionText.isEmpty {
            extra += 38 // divider + accept row + its padding
        }
        if case .error = correctionEngine.state {
            extra += 26 // divider + error text + its padding
        }

        // No defaultHeight floor here — when resize is on the window matches the
        // measured content so short corrections render flush without a gap.
        return Self.chromeHeight + textAreaHeight + extra
    }

    private func screenContaining(_ rect: CGRect) -> NSScreen? {
        NSScreen.screens.first { NSIntersectsRect($0.frame, rect) }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Speech bubble shape

private struct SpeechBubbleShape: Shape {
    var cornerRadius: CGFloat = 10
    var tailWidth: CGFloat = BubbleGeometry.tailWidth
    var tailHeight: CGFloat = BubbleGeometry.tailHeight
    var tailX: CGFloat

    var animatableData: CGFloat {
        get { tailX }
        set { tailX = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = cornerRadius
        let bubble = CGRect(x: rect.minX, y: rect.minY + tailHeight, width: rect.width, height: rect.height - tailHeight)
        let apexX = min(max(tailX, bubble.minX + r + tailWidth / 2), bubble.maxX - r - tailWidth / 2)

        var path = Path()
        path.move(to: CGPoint(x: bubble.minX + r, y: bubble.minY))
        path.addLine(to: CGPoint(x: apexX - tailWidth / 2, y: bubble.minY))
        path.addLine(to: CGPoint(x: apexX, y: rect.minY))
        path.addLine(to: CGPoint(x: apexX + tailWidth / 2, y: bubble.minY))
        path.addLine(to: CGPoint(x: bubble.maxX - r, y: bubble.minY))
        path.addArc(center: CGPoint(x: bubble.maxX - r, y: bubble.minY + r), radius: r, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: bubble.maxX, y: bubble.maxY - r))
        path.addArc(center: CGPoint(x: bubble.maxX - r, y: bubble.maxY - r), radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: bubble.minX + r, y: bubble.maxY))
        path.addArc(center: CGPoint(x: bubble.minX + r, y: bubble.maxY - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: bubble.minX, y: bubble.minY + r))
        path.addArc(center: CGPoint(x: bubble.minX + r, y: bubble.minY + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}

// MARK: - SwiftUI content

private struct OverlayContentView: View {
    @ObservedObject var correctionEngine: CorrectionEngine
    @ObservedObject var geometry: BubbleGeometry
    @ObservedObject private var settings = SettingsStore.shared
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        bubbleBody
            .background {
                SpeechBubbleShape(tailX: geometry.tailX)
                    .fill(.regularMaterial)
            }
            .clipShape(SpeechBubbleShape(tailX: geometry.tailX))
            .overlay {
                SpeechBubbleShape(tailX: geometry.tailX)
                    .stroke(.separator, lineWidth: 0.5)
            }
            .padding(4) // room for the shadow to breathe
    }

    private var bubbleBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Circle()
                    .fill(correctionEngine.state == .correcting ? Color.orange : Color.green)
                    .frame(width: 7, height: 7)
                    .animation(.easeInOut(duration: 0.3), value: correctionEngine.state == .correcting)

                Text(headerLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)

                Spacer()

                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Divider()

            // Correction text. When the resize setting is off, this is a fixed 100pt
            // scrollable area, same as always. When it's on, OverlayPanel measures the
            // text itself with NSString.boundingRect (SwiftUI's own size-reporting
            // mechanisms — PreferenceKey, intrinsicContentSize, fittingSize — all proved
            // unreliable for this dynamically-streaming, AppKit-hosted content) and
            // resizes the window to fit, so the text area just needs a height that
            // matches that same computation, clamped the same way, so the ScrollView's
            // viewport and the window's actual size agree.
            ScrollView {
                Text(correctionEngine.correctionText.isEmpty ? " " : correctionEngine.correctionText)
                    .font(.system(size: OverlayPanel.textFontSize))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, OverlayPanel.textHPadding)
                    .padding(.vertical, OverlayPanel.textVPadding)
            }
            .frame(height: settings.resizeBubbleToFitText ? textAreaHeight : 100)

            // Accept button — visible only when stream is complete
            if correctionEngine.state == .finished && !correctionEngine.correctionText.isEmpty {
                Divider()
                HStack {
                    Text("⌃Return to accept")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Accept") {
                        onAccept()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.accentColor)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            if case .error(let msg) = correctionEngine.state {
                Divider()
                Text(msg)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
        }
        .padding(.top, BubbleGeometry.tailHeight)
    }

    /// Height for the ScrollView when resize-to-fit is enabled. Delegates to
    /// OverlayPanel's single measurement helper so the viewport always agrees with
    /// the window height.
    private var textAreaHeight: CGFloat {
        OverlayPanel.measuredTextAreaHeight(for: correctionEngine.correctionText)
    }

    private var headerLabel: String {
        switch correctionEngine.state {
        case .idle:        return "GrammarBar"
        case .correcting:  return "Correcting…"
        case .finished:    return "Suggested correction"
        case .error:       return "Error"
        }
    }
}
