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
}

// MARK: - Panel

final class OverlayPanel: NSPanel {
    private let correctionEngine: CorrectionEngine
    private let onAccept: () -> Void
    private let onCopy: () -> Void
    private let onDismiss: () -> Void
    private let geometry = BubbleGeometry()
    private let hostingView: NSHostingView<OverlayContentView>
    private var cancellables = Set<AnyCancellable>()

    // Last status-item frame we were positioned against, and the horizontal
    // origin computed from it. Retained so we can re-derive the panel's frame
    // whenever its height changes without needing a fresh position() call.
    private var anchorFrame: CGRect?
    private var originX: CGFloat = 0

    init(
        correctionEngine: CorrectionEngine,
        onAccept: @escaping () -> Void,
        onCopy: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.correctionEngine = correctionEngine
        self.onAccept = onAccept
        self.onCopy = onCopy
        self.onDismiss = onDismiss

        let content = OverlayContentView(
            correctionEngine: correctionEngine,
            geometry: geometry,
            onAccept: onAccept,
            onCopy: onCopy,
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
    }

    /// Positions the bubble directly below the menu bar status item.
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
            tailX = min(max(tailX, 24), panelWidth - 24)
        }

        geometry.tailX = tailX
        anchorFrame = statusItemFrame
        originX = computedOriginX
        relayout()
    }

    private func relayout() {
        guard let anchorFrame else { return }
        let height = desiredHeight
        let originY = anchorFrame.minY - height
        let newFrame = NSRect(x: originX, y: originY, width: BubbleGeometry.panelWidth, height: height)
        guard newFrame != frame else { return }
        setFrame(newFrame, display: true)
    }

    // MARK: - Layout constants

    static let textHPadding: CGFloat = 12
    static let textVPadding: CGFloat = 8
    static let textFontSize: CGFloat = 13
    static let minTextAreaHeight: CGFloat = 40
    static let maxTextAreaHeight: CGFloat = 300

    /// Fixed chrome: tail + header + divider + outer padding.
    private static let chromeHeight: CGFloat = BubbleGeometry.defaultHeight - 100

    // MARK: - Text measurement

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

    private var desiredHeight: CGFloat {
        let isFinished = correctionEngine.state == .finished
            && !correctionEngine.correctionText.isEmpty

        let displayText: String
        if case .finished(let alts) = correctionEngine.rephraseState,
           correctionEngine.rephraseIndex < alts.count {
            displayText = alts[correctionEngine.rephraseIndex]
        } else {
            displayText = correctionEngine.correctionText
        }

        guard SettingsStore.shared.resizeBubbleToFitText else {
            return BubbleGeometry.defaultHeight
        }

        let textAreaHeight = Self.measuredTextAreaHeight(for: displayText)

        var extra: CGFloat = 0
        if isFinished {
            extra += 20  // readability row
            extra += 38  // action row (copy / rephrase / why / accept)
        }
        if case .error = correctionEngine.state {
            extra += 26
        }

        // Explanation area
        switch correctionEngine.explanationState {
        case .loading:
            extra += 44  // divider + spinner row
        case .finished(let text):
            extra += 1   // divider
            extra += Self.measuredExplanationHeight(for: text)
        default:
            break
        }

        return Self.chromeHeight + textAreaHeight + extra
    }

    private func screenContaining(_ rect: CGRect) -> NSScreen? {
        NSScreen.screens.first { NSIntersectsRect($0.frame, rect) }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Word diff

struct DiffToken: Identifiable {
    enum Kind { case same, removed, added }
    let id = UUID()
    let text: String
    let kind: Kind
}

enum WordDiff {
    /// Compute a word-level diff between two strings using LCS.
    static func compute(original: String, corrected: String) -> [DiffToken] {
        let origWords = words(original)
        let corrWords = words(corrected)

        guard origWords != corrWords else {
            return [DiffToken(text: corrected, kind: .same)]
        }

        let m = origWords.count
        let n = corrWords.count

        // Build LCS DP table
        var dp = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)
        for i in 1...m {
            for j in 1...n {
                if origWords[i - 1].lowercased() == corrWords[j - 1].lowercased() {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        // Trace back through DP to build token list
        var tokens: [DiffToken] = []
        var i = m, j = n
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && origWords[i - 1].lowercased() == corrWords[j - 1].lowercased() {
                tokens.append(DiffToken(text: corrWords[j - 1], kind: .same))
                i -= 1; j -= 1
            } else if j > 0 && (i == 0 || dp[i][j - 1] >= dp[i - 1][j]) {
                tokens.append(DiffToken(text: corrWords[j - 1], kind: .added))
                j -= 1
            } else {
                tokens.append(DiffToken(text: origWords[i - 1], kind: .removed))
                i -= 1
            }
        }

        return tokens.reversed()
    }

    private static func words(_ text: String) -> [String] {
        // Split on whitespace but keep punctuation attached to words
        text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
    }
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

struct OverlayContentView: View {
    @ObservedObject var correctionEngine: CorrectionEngine
    @ObservedObject var geometry: BubbleGeometry
    @ObservedObject private var settings = SettingsStore.shared
    let onAccept: () -> Void
    let onCopy: () -> Void
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
            .padding(4)
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
                    .lineLimit(1)

                Spacer(minLength: 4)

                // Readability summary (when finished)
                if correctionEngine.state == .finished,
                   !correctionEngine.originalText.isEmpty {
                    let r = Readability.analyse(correctionEngine.originalText)
                    Text("\(r.wordCount) words · \(r.grade.rawValue)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }

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
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            Divider()

            // Text area — diff when finished, plain while streaming
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
                        // Show word-level diff
                        diffTextView
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    } else {
                        // Streaming: plain text
                        Text(correctionEngine.correctionText.isEmpty ? " " : correctionEngine.correctionText)
                            .font(.system(size: OverlayPanel.textFontSize))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, OverlayPanel.textHPadding)
                .padding(.vertical, OverlayPanel.textVPadding)
            }
            .frame(height: settings.resizeBubbleToFitText ? textAreaHeight : 100)

            // Action footer row — visible only when finished
            if correctionEngine.state == .finished && !correctionEngine.correctionText.isEmpty {
                Divider()
                actionRow
            }

            // Explanation area
            explanationView

            // Error row
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

    // MARK: - Diff text view

    @ViewBuilder
    private var diffTextView: some View {
        let tokens = WordDiff.compute(
            original: correctionEngine.originalText,
            corrected: correctionEngine.correctionText
        )
        diffText(tokens: tokens)
            .font(.system(size: OverlayPanel.textFontSize))
    }

    private func diffText(tokens: [DiffToken]) -> Text {
        tokens.reduce(Text("")) { result, token in
            let word = token.text
            let space = Text(" ")
            switch token.kind {
            case .same:
                return result + Text(word) + space
            case .added:
                return result + Text(word).foregroundColor(.green).bold() + space
            case .removed:
                return result + Text(word).foregroundColor(.red).strikethrough() + space
            }
        }
    }

    // MARK: - Action row

    private var actionRow: some View {
        HStack(spacing: 6) {
            Text("⌃Return to accept")
                .font(.system(size: 10))
                .foregroundColor(.secondary)

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
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
    }

    // MARK: - Layout helpers

    private var textAreaHeight: CGFloat {
        let displayText: String
        if case .finished(let alts) = correctionEngine.rephraseState,
           correctionEngine.rephraseIndex < alts.count {
            displayText = alts[correctionEngine.rephraseIndex]
        } else {
            displayText = correctionEngine.correctionText
        }
        return OverlayPanel.measuredTextAreaHeight(for: displayText)
    }

    private func explanationHeight(for text: String) -> CGFloat {
        OverlayPanel.measuredExplanationHeight(for: text)
    }

    private var headerLabel: String {
        switch correctionEngine.state {
        case .idle:        return "GrammarBar"
        case .correcting:  return "Correcting…"
        case .finished:
            if case .finished = correctionEngine.rephraseState {
                return "Alternative \(correctionEngine.rephraseIndex + 1)"
            }
            return "Suggested correction"
        case .error:       return "Error"
        }
    }
}
