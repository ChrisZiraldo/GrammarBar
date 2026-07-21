import AppKit
import SwiftUI

// MARK: - Bubble geometry (published so SwiftUI redraws the tail on reposition)

final class BubbleGeometry: ObservableObject {
    static let tailWidth: CGFloat = 18
    static let tailHeight: CGFloat = 9
    static let panelWidth: CGFloat = 360

    // Horizontal position of the tail's apex, in the panel's own coordinate space.
    @Published var tailX: CGFloat = BubbleGeometry.panelWidth - 30
}

// MARK: - Panel

final class OverlayPanel: NSPanel {
    private let correctionEngine: CorrectionEngine
    private let onAccept: () -> Void
    private let onDismiss: () -> Void
    private let geometry = BubbleGeometry()

    init(correctionEngine: CorrectionEngine, onAccept: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.correctionEngine = correctionEngine
        self.onAccept = onAccept
        self.onDismiss = onDismiss

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: BubbleGeometry.panelWidth, height: 160 + BubbleGeometry.tailHeight),
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

        let content = OverlayContentView(
            correctionEngine: correctionEngine,
            geometry: geometry,
            onAccept: onAccept,
            onDismiss: onDismiss
        )
        contentView = NSHostingView(rootView: content)
    }

    /// Positions the bubble directly below the menu bar status item, with its
    /// tail pointing up at the icon. `statusItemFrame` is in AppKit screen
    /// coordinates (origin bottom-left), as returned by the status item's button window.
    func position(belowStatusItem statusItemFrame: CGRect) {
        let panelWidth = BubbleGeometry.panelWidth
        let tailInsetFromRight: CGFloat = 30
        let iconMidX = statusItemFrame.midX

        var originX = iconMidX - (panelWidth - tailInsetFromRight)
        var tailX = panelWidth - tailInsetFromRight

        if let screen = screenContaining(statusItemFrame) ?? NSScreen.main {
            let visibleFrame = screen.visibleFrame
            let minX = visibleFrame.minX + 8
            let maxX = visibleFrame.maxX - panelWidth - 8
            if originX > maxX {
                tailX += originX - maxX
                originX = maxX
            }
            if originX < minX {
                tailX -= minX - originX
                originX = minX
            }
            // Keep the tail apex from sliding past the bubble's rounded corners.
            tailX = min(max(tailX, 24), panelWidth - 24)
        }

        geometry.tailX = tailX
        let originY = statusItemFrame.minY - frame.height
        setFrameOrigin(CGPoint(x: originX, y: originY))
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

            // Correction text
            ScrollView {
                Text(correctionEngine.correctionText.isEmpty ? " " : correctionEngine.correctionText)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .frame(maxHeight: 100)

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

    private var headerLabel: String {
        switch correctionEngine.state {
        case .idle:        return "GrammarBar"
        case .correcting:  return "Correcting…"
        case .finished:    return "Suggested correction"
        case .error:       return "Error"
        }
    }
}
