import AppKit
import Combine
import SwiftUI

// MARK: - Bubble geometry (published so SwiftUI redraws the tail on reposition)

final class BubbleGeometry: ObservableObject {
    static let tailWidth: CGFloat = 18
    static let tailHeight: CGFloat = 9
    static let panelWidth: CGFloat = 380
    static let defaultHeight: CGFloat = 160 + BubbleGeometry.tailHeight

    // Horizontal position of the tail's apex, in the panel's own coordinate space.
    @Published var tailX: CGFloat = BubbleGeometry.panelWidth - 30

    // True when the bubble floats above its anchor, so the tail points down from the
    // bottom edge instead of up from the top edge.
    @Published var tailOnBottom = false

    // Actual rendered height of the text area's content (including its own padding),
    // reported by SwiftUI via a GeometryReader. Used to size the bubble precisely so
    // long/bold/diff text is never clipped.
    @Published var measuredTextHeight: CGFloat = 40

    // Rendered height of the whole bubble (tail included), also reported by SwiftUI.
    // The panel is sized from this so every row — however many are showing — fits.
    @Published var measuredTotalHeight: CGFloat = 0

    // Drives the small slide when the bubble appears. The window itself fades via
    // alphaValue (so its shadow fades too); this only nudges the content.
    @Published var isShown = false
}

// MARK: - Post-accept undo toast

/// Drives the compact "Corrected · Undo" state the bubble collapses into after a
/// correction is accepted.
final class ToastModel: ObservableObject {
    @Published var isShowing = false
}

// MARK: - Preference keys

private struct TextContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct TotalHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Panel

final class OverlayPanel: NSPanel {

    /// What the bubble is attached to.
    enum PlacementTarget {
        /// The menu-bar icon: bubble hangs below it, tail pointing up.
        case statusItem(CGRect)
        /// A text field or cursor line: bubble floats above it, tail pointing down
        /// (or below it, if there's no room above). Rect is in AppKit screen coordinates.
        case textField(CGRect)
    }

    private let correctionEngine: CorrectionEngine
    private let onAccept: () -> Void
    private let onCopy: () -> Void
    private let onDismiss: () -> Void
    private let onUndo: () -> Void
    private let geometry = BubbleGeometry()
    private let toast = ToastModel()
    private var toastDismissWork: DispatchWorkItem?
    /// Logical visibility: true from `present()` until `hide()`, even while a fade is in flight.
    private var isPresented = false
    /// Invalidates in-flight fade-out completions when the bubble is shown again.
    private var visibilityToken = 0
    private let hostingView: NSHostingView<OverlayContentView>
    private var cancellables = Set<AnyCancellable>()

    // Last placement we were positioned against, and the horizontal origin computed
    // from it. Retained so we can re-derive the panel's frame whenever its height
    // changes without needing a fresh place() call.
    private var placement: PlacementTarget?
    private var originX: CGFloat = 0

    /// True from `present()` until `hide()`.
    var isShowing: Bool { isPresented }

    /// True while the compact "Corrected · Undo" toast is what's showing.
    var isToastShowing: Bool { isPresented && toast.isShowing }

    init(
        correctionEngine: CorrectionEngine,
        onAccept: @escaping () -> Void,
        onCopy: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        onUndo: @escaping () -> Void
    ) {
        self.correctionEngine = correctionEngine
        self.onAccept = onAccept
        self.onCopy = onCopy
        self.onDismiss = onDismiss
        self.onUndo = onUndo

        let content = OverlayContentView(
            correctionEngine: correctionEngine,
            geometry: geometry,
            toast: toast,
            onAccept: onAccept,
            onCopy: onCopy,
            onDismiss: onDismiss,
            onUndo: onUndo
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

        // Disable SwiftUI's automatic min/max sizing — we drive the frame manually.
        hostingView.sizingOptions = []
        contentView = hostingView

        // Re-measure and resize whenever the content that affects height changes.
        correctionEngine.$correctionText
            .combineLatest(correctionEngine.$state)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.relayout() }
            .store(in: &cancellables)

        correctionEngine.$rephraseState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.relayout() }
            .store(in: &cancellables)

        correctionEngine.$explanationState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.relayout() }
            .store(in: &cancellables)

        SettingsStore.shared.$resizeBubbleToFitText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.relayout() }
            .store(in: &cancellables)

        toast.$isShowing
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.relayout() }
            .store(in: &cancellables)

        // Resize whenever SwiftUI reports a new rendered height.
        geometry.$measuredTotalHeight
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.relayout() }
            .store(in: &cancellables)
    }

    // MARK: - Show / hide

    /// Shows the bubble. Any leftover undo toast is cleared so a new suggestion
    /// never opens in the collapsed "Corrected" state.
    func present() {
        if toast.isShowing { cancelToast() }
        fadeIn()
    }

    /// Hides the bubble (and any undo toast) with a short fade.
    func hide() {
        cancelToast()
        isPresented = false
        guard isVisible else { return }

        visibilityToken += 1
        let token = visibilityToken
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Ignore if the bubble was re-presented while fading out.
            guard let self, self.visibilityToken == token, !self.isPresented else { return }
            self.orderOut(nil)
            self.alphaValue = 1
            self.geometry.isShown = false
        })
    }

    /// Collapses the bubble into a compact "Corrected · Undo" toast that dismisses itself.
    func showUndoToast(duration: TimeInterval = 5) {
        toastDismissWork?.cancel()
        toast.isShowing = true
        fadeIn()

        let work = DispatchWorkItem { [weak self] in self?.hide() }
        toastDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func fadeIn() {
        visibilityToken += 1
        guard !isPresented else { return }
        isPresented = true

        // Start transparent and slightly offset, unless we're mid-fade-out, in which
        // case just reverse from wherever the fade got to.
        if !isVisible {
            geometry.isShown = false
            alphaValue = 0
            orderFront(nil)
        }

        // Defer so SwiftUI renders the "hidden" state first and the slide animates.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isPresented else { return }
            self.geometry.isShown = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                self.animator().alphaValue = 1
            }
        }
    }

    private func cancelToast() {
        toastDismissWork?.cancel()
        toastDismissWork = nil
        toast.isShowing = false
    }

    // MARK: - Placement

    /// Attaches the bubble to a menu-bar icon or a text field and repositions it.
    func place(_ target: PlacementTarget) {
        let panelWidth = BubbleGeometry.panelWidth

        // Where the tail's apex should land, and how far from the panel's left edge.
        let anchorX: CGFloat
        let tailInsetFromLeft: CGFloat
        let anchorRect: CGRect

        switch target {
        case .statusItem(let frame):
            anchorRect = frame
            anchorX = frame.midX
            tailInsetFromLeft = panelWidth - 30
        case .textField(let rect):
            anchorRect = rect
            // A narrow rect is a cursor position; a wide one is a whole field, so
            // point near its left end.
            anchorX = rect.width < 60 ? rect.midX : rect.minX + 44
            tailInsetFromLeft = 36
        }

        var computedOriginX = anchorX - tailInsetFromLeft
        var tailX = tailInsetFromLeft

        if let screen = screenContaining(anchorRect) ?? NSScreen.main {
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
            tailX = min(max(tailX, 24), panelWidth - 24)
        }

        geometry.tailX = tailX
        placement = target
        originX = computedOriginX
        relayout()
    }

    private func relayout() {
        guard let placement else { return }
        let height = desiredHeight

        let originY: CGFloat
        var tailOnBottom = false

        switch placement {
        case .statusItem(let frame):
            originY = frame.minY - height

        case .textField(let rect):
            let gap: CGFloat = 4
            let visible = (screenContaining(rect) ?? NSScreen.main)?.visibleFrame
            let aboveY = rect.maxY + gap

            if let visible, aboveY + height > visible.maxY {
                // No room above — drop below the field instead, tail pointing up.
                originY = max(rect.minY - height - gap, visible.minY)
            } else {
                originY = aboveY
                tailOnBottom = true
            }
        }

        if geometry.tailOnBottom != tailOnBottom {
            geometry.tailOnBottom = tailOnBottom
        }

        let newFrame = NSRect(x: originX, y: originY, width: BubbleGeometry.panelWidth, height: height)
        guard newFrame != frame else { return }

        // Animate height changes while the bubble is on screen; position it
        // instantly when it's hidden or just being placed.
        if isPresented && isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.animator().setFrame(newFrame, display: true)
            }
        } else {
            setFrame(newFrame, display: true)
        }
    }

    // MARK: - Layout constants

    static let textHPadding: CGFloat = 12
    static let textVPadding: CGFloat = 8
    static let textFontSize: CGFloat = 13
    static let minTextAreaHeight: CGFloat = 40
    static let maxTextAreaHeight: CGFloat = 300

    /// Toast row height (the panel itself is sized from the measured content).
    static let toastRowHeight: CGFloat = 34

    // MARK: - Text measurement

    static func measuredExplanationHeight(for text: String) -> CGFloat {
        let t = text.isEmpty ? " " : text
        let width = BubbleGeometry.panelWidth - textHPadding * 2
        let bounds = (t as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 11)]
        )
        return min(max(ceil(bounds.height) + textVPadding * 2, 30), 140)
    }

    /// The panel is as tall as SwiftUI says the bubble is, plus the 4pt outer padding
    /// on each side. Until the first measurement arrives, fall back to a default.
    private var desiredHeight: CGFloat {
        let measured = geometry.measuredTotalHeight
        guard measured > 0 else { return BubbleGeometry.defaultHeight }
        return ceil(measured) + 8
    }

    private func screenContaining(_ rect: CGRect) -> NSScreen? {
        NSScreen.screens.first { NSIntersectsRect($0.frame, rect) }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Wrapping layout (flows words like text, one view per word)

private struct LineBreakCountKey: LayoutValueKey {
    static let defaultValue = 0
}

private extension View {
    /// Marks a zero-size view as a forced line break (count = number of "\n").
    func lineBreak(_ count: Int) -> some View {
        layoutValue(key: LineBreakCountKey.self, value: count)
    }
}

private struct WrapLayout: Layout {
    var spacing: CGFloat = 3.5
    var lineSpacing: CGFloat = 3
    var emptyLineHeight: CGFloat = 16

    private func arrange(width: CGFloat, subviews: Subviews) -> (positions: [CGPoint], size: CGSize) {
        var positions = [CGPoint](repeating: .zero, count: subviews.count)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            let breaks = subview[LineBreakCountKey.self]
            if breaks > 0 {
                y += (rowHeight > 0 ? rowHeight : emptyLineHeight) + lineSpacing
                if breaks > 1 { y += CGFloat(breaks - 1) * (emptyLineHeight + lineSpacing) }
                x = 0
                rowHeight = 0
                positions[index] = CGPoint(x: 0, y: y)
                continue
            }

            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + spacing + size.width > width {
                y += rowHeight + lineSpacing
                x = 0
                rowHeight = 0
            }
            if x > 0 { x += spacing }
            positions[index] = CGPoint(x: x, y: y)
            x += size.width
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x)
        }

        let usedWidth = width.isFinite ? width : maxX
        return (positions, CGSize(width: usedWidth, height: y + rowHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let point = result.positions[index]
            subview.place(
                at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                anchor: .topLeading,
                proposal: .unspecified
            )
        }
    }
}

// MARK: - Speech bubble shape

private struct SpeechBubbleShape: Shape {
    var cornerRadius: CGFloat = 10
    var tailWidth: CGFloat = BubbleGeometry.tailWidth
    var tailHeight: CGFloat = BubbleGeometry.tailHeight
    var tailX: CGFloat
    /// Draws the tail on the bottom edge (pointing down) instead of the top.
    var tailAtBottom = false

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

        guard tailAtBottom else { return path }
        // Mirror vertically so the tail hangs off the bottom edge.
        return path.applying(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: rect.minY + rect.maxY))
    }
}

// MARK: - Pending text (original, dimmed, while the model works)

private struct PendingTextView: View {
    let text: String
    let isWorking: Bool
    @State private var pulse = false

    var body: some View {
        Text(text.isEmpty ? " " : text)
            .font(.system(size: OverlayPanel.textFontSize))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(isWorking ? (pulse ? 0.95 : 0.5) : 0.8)
            .onAppear {
                guard isWorking else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

// MARK: - One reviewable edit in the diff

private struct DiffChangeView: View {
    let change: DiffChange
    let isRejected: Bool
    let onToggle: () -> Void
    let onProtect: (String) -> Void

    @State private var hovering = false

    var body: some View {
        label
            .font(.system(size: OverlayPanel.textFontSize))
            .padding(.horizontal, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(hovering ? Color.accentColor.opacity(0.18) : Color.clear)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: onToggle)
            .contextMenu {
                Button(isRejected ? "Apply this change" : "Keep my original") { onToggle() }
                if let original = change.original {
                    let core = DictionaryGuard.core(of: original)
                    if !core.isEmpty {
                        Button("Never change “\(core)”") { onProtect(original) }
                    }
                }
            }
            .help(isRejected ? "Reverted — click to apply this change again" : "Click to keep your original instead")
    }

    private var label: Text {
        if isRejected {
            if let original = change.original {
                // Back to the user's own wording.
                return Text(original).foregroundColor(.orange).underline()
            }
            // A rejected insertion: show what won't be added, struck through, so it
            // can be clicked again.
            return Text(change.corrected ?? "").foregroundColor(.secondary).strikethrough()
        }

        var result = Text("")
        for (index, piece) in change.pieces.enumerated() {
            if index > 0 && piece.spaceBefore { result = result + Text(" ") }
            switch piece.kind {
            case .same:
                result = result + Text(piece.text)
            case .added:
                result = result + Text(piece.text).foregroundColor(.green).bold()
            case .removed:
                result = result + Text(piece.text).foregroundColor(.red).strikethrough()
            }
        }
        return result
    }
}

// MARK: - SwiftUI content

struct OverlayContentView: View {
    @ObservedObject var correctionEngine: CorrectionEngine
    @ObservedObject var geometry: BubbleGeometry
    @ObservedObject var toast: ToastModel
    @ObservedObject private var settings = SettingsStore.shared
    let onAccept: () -> Void
    let onCopy: () -> Void
    let onDismiss: () -> Void
    let onUndo: () -> Void

    var body: some View {
        Group {
            if toast.isShowing {
                toastBody
            } else {
                bubbleBody
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: TotalHeightKey.self, value: proxy.size.height)
            }
        )
        .onPreferenceChange(TotalHeightKey.self) { height in
            geometry.measuredTotalHeight = height
        }
        .background {
            SpeechBubbleShape(tailX: geometry.tailX, tailAtBottom: geometry.tailOnBottom)
                .fill(.regularMaterial)
        }
        .clipShape(SpeechBubbleShape(tailX: geometry.tailX, tailAtBottom: geometry.tailOnBottom))
        .overlay {
            SpeechBubbleShape(tailX: geometry.tailX, tailAtBottom: geometry.tailOnBottom)
                .stroke(.separator, lineWidth: 0.5)
        }
        .padding(4)
        .offset(y: geometry.isShown ? 0 : (geometry.tailOnBottom ? 4 : -4))
        .animation(.easeOut(duration: 0.18), value: geometry.isShown)
    }

    // MARK: - Tail spacing

    private var tailTopPadding: CGFloat { geometry.tailOnBottom ? 0 : BubbleGeometry.tailHeight }
    private var tailBottomPadding: CGFloat { geometry.tailOnBottom ? BubbleGeometry.tailHeight : 0 }

    // MARK: - Undo toast

    private var toastBody: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundColor(.green)

            Text("Corrected")
                .font(.system(size: 12, weight: .medium))

            Spacer(minLength: 4)

            Text("⌃Z")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

            Button("Undo") {
                onUndo()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .frame(height: OverlayPanel.toastRowHeight)
        .padding(.top, tailTopPadding)
        .padding(.bottom, tailBottomPadding)
    }

    // MARK: - Bubble

    private var isFinishedWithText: Bool {
        correctionEngine.state == .finished && !correctionEngine.correctionText.isEmpty
    }

    private var bubbleBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            textArea

            // Review footer — visible only when finished
            if isFinishedWithText {
                Divider()
                readabilityRow
                actionRow
            }

            // Explanation area
            explanationView

            // Error row
            if case .error(let msg) = correctionEngine.state {
                Divider()
                errorRow(msg)
            }
        }
        .padding(.top, tailTopPadding)
        .padding(.bottom, tailBottomPadding)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            statusIndicator

            Text(headerLabel)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)

            Spacer(minLength: 4)

            // On-the-fly style picker — changes this correction only, not global settings.
            styleMenu

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss (Esc)")
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch correctionEngine.state {
        case .correcting:
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 14, height: 14)
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundColor(.green)
                .frame(width: 14, height: 14)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundColor(.orange)
                .frame(width: 14, height: 14)
        default:
            Circle()
                .fill(Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
                .frame(width: 14, height: 14)
        }
    }

    // MARK: - Text area

    private var textArea: some View {
        ScrollView {
            Group {
                if case .finished(let alts) = correctionEngine.rephraseState,
                   correctionEngine.rephraseIndex < alts.count {
                    // Show current rephrase alternative as plain text
                    Text(alts[correctionEngine.rephraseIndex])
                        .font(.system(size: OverlayPanel.textFontSize))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                } else if correctionEngine.state == .finished,
                          !correctionEngine.originalText.isEmpty {
                    // Interactive word-level diff
                    diffView
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                } else {
                    // Waiting on the model: the original text, dimmed
                    PendingTextView(
                        text: correctionEngine.originalText,
                        isWorking: correctionEngine.state == .correcting
                    )
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: correctionEngine.state == .finished)
            .padding(.horizontal, OverlayPanel.textHPadding)
            .padding(.vertical, OverlayPanel.textVPadding)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: TextContentHeightKey.self,
                        value: proxy.size.height
                    )
                }
            )
        }
        .frame(height: settings.resizeBubbleToFitText ? textAreaHeight : 100)
        .onPreferenceChange(TextContentHeightKey.self) { height in
            geometry.measuredTextHeight = height
        }
    }

    // MARK: - Style menu

    private var styleMenu: some View {
        Menu {
            ForEach(CorrectionMode.allCases) { mode in
                Button {
                    correctionEngine.applyMode(mode)
                } label: {
                    if mode == correctionEngine.activeMode {
                        Label(mode.displayName, systemImage: "checkmark")
                    } else {
                        Text(mode.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 2) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 9))
                Text(correctionEngine.activeMode.displayName)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Change the correction style for this text only")
    }

    // MARK: - Interactive diff

    private var diffView: some View {
        let segments = WordDiff.segments(
            original: correctionEngine.originalText,
            corrected: correctionEngine.correctionText
        )
        return WrapLayout {
            ForEach(segments) { segment in
                segmentView(segment)
            }
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: DiffSegment) -> some View {
        switch segment.content {
        case .same(let text):
            if WordDiff.isBreak(text) {
                Color.clear
                    .frame(width: 0, height: 0)
                    .lineBreak(text.count)
            } else {
                Text(text)
                    .font(.system(size: OverlayPanel.textFontSize))
            }

        case .change(let change):
            DiffChangeView(
                change: change,
                isRejected: correctionEngine.rejectedChanges.contains(change.id),
                onToggle: { correctionEngine.toggleChange(change.id) },
                onProtect: { correctionEngine.protectWord($0) }
            )
        }
    }

    // MARK: - Readability

    private var readabilityRow: some View {
        let before = Readability.analyse(correctionEngine.originalText)
        let after = Readability.analyse(correctionEngine.textToApply)
        let summary = before.grade == after.grade
            ? "\(after.wordCount) words · \(after.grade.rawValue)"
            : "\(after.wordCount) words · \(before.grade.rawValue) → \(after.grade.rawValue)"

        return HStack {
            Text(summary)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .help(String(
                    format: "Flesch reading ease: %.0f → %.0f",
                    before.fleschScore, after.fleschScore
                ))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 7)
    }

    // MARK: - Action row

    private var actionRow: some View {
        HStack(spacing: 6) {
            Text("⌃Return accept · Esc dismiss")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)

            Spacer()

            // Copy
            Button {
                onCopy()
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("Copy to clipboard")

            // Rephrase
            rephraseButton

            // Why? (explanation)
            Button {
                correctionEngine.requestExplanation()
            } label: {
                switch correctionEngine.explanationState {
                case .loading:
                    ProgressView().scaleEffect(0.5).frame(width: 16, height: 16)
                default:
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 11))
                        .foregroundColor(
                            correctionEngine.explanationState == .idle ? .secondary : .accentColor
                        )
                }
            }
            .buttonStyle(.plain)
            .help("Explain changes")

            // Accept
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

    @ViewBuilder
    private var rephraseButton: some View {
        switch correctionEngine.rephraseState {
        case .loading:
            ProgressView().scaleEffect(0.5).frame(width: 16, height: 16)

        case .finished(let alts):
            Button {
                correctionEngine.nextRephrase()
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.2.circlepath")
                        .font(.system(size: 10))
                    Text("\(correctionEngine.rephraseIndex + 1)/\(alts.count)")
                        .font(.system(size: 10))
                }
                .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
            .help("Cycle alternatives")

        default:
            Button {
                correctionEngine.requestRephrase()
            } label: {
                Image(systemName: "arrow.2.circlepath")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Show alternatives")
        }
    }

    // MARK: - Error row

    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(message)
                .font(.system(size: 11))
                .foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            // Only possible once there's text to re-run (not for "no model" errors).
            if !correctionEngine.originalText.isEmpty {
                Button("Retry") {
                    correctionEngine.retry()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Explanation view

    @ViewBuilder
    private var explanationView: some View {
        switch correctionEngine.explanationState {
        case .idle:
            EmptyView()

        case .loading:
            Divider()
            HStack {
                ProgressView().scaleEffect(0.6)
                Text("Explaining changes…")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

        case .finished(let text):
            Divider()
            ScrollView {
                Text(text)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
            .frame(height: explanationHeight(for: text))

        case .error(let msg):
            Divider()
            Text("Could not explain: \(msg)")
                .font(.system(size: 11))
                .foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
    }

    // MARK: - Layout helpers

    private var textAreaHeight: CGFloat {
        min(
            max(geometry.measuredTextHeight, OverlayPanel.minTextAreaHeight),
            OverlayPanel.maxTextAreaHeight
        )
    }

    private func explanationHeight(for text: String) -> CGFloat {
        OverlayPanel.measuredExplanationHeight(for: text)
    }

    private var headerLabel: String {
        switch correctionEngine.state {
        case .idle:        return "GrammarBar"
        case .unchanged:   return "Looks good"
        case .correcting:  return "Checking…"
        case .finished:
            if case .finished = correctionEngine.rephraseState {
                return "Alternative \(correctionEngine.rephraseIndex + 1)"
            }
            let reverted = correctionEngine.rejectedChanges.count
            return reverted > 0
                ? "Suggested correction · \(reverted) reverted"
                : "Suggested correction"
        case .error:       return "Something went wrong"
        }
    }
}
