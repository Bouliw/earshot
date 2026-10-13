import AppKit
import SwiftUI

/// The transcript as one AppKit text view. SwiftUI's selectable `Text` keeps a selection inside a single view,
/// so with one `Text` per turn, ⌘A and drag selections stopped at the end of a paragraph.
struct TranscriptText: NSViewRepresentable {
    let turns: [Turn]
    let startedAt: Date
    let query: String
    /// (speaker, text) of the line being spoken, nil when not live.
    let live: (String?, String)?
    @Binding var following: Bool
    /// Changes when the view should scroll down to the live line with an animation.
    let jump: Int

    func makeCoordinator() -> TranscriptScroller { TranscriptScroller() }

    func makeNSView(context: Context) -> NSScrollView { context.coordinator.scrollView }

    func updateNSView(_ view: NSScrollView, context: Context) {
        let scroller = context.coordinator
        scroller.following = $following
        scroller.show(TranscriptDocument(turns: turns, startedAt: startedAt, query: query, live: live),
                      query: query, startedAt: startedAt, jump: jump)
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: TranscriptScroller) { coordinator.stop() }
}

/// Owns the scroll view and text view: applies new text without losing the selection, and follows the end.
@MainActor
final class TranscriptScroller {
    let scrollView: FollowingScrollView
    let textView: TranscriptTextView
    var following: Binding<Bool>?
    private let storage = NSTextStorage()
    private var committedLength = 0
    private var query: String?
    private var startedAt: Date?
    private var jump = 0
    private var cursor: NSRange?
    private var cursorShown = true
    private var blink: Timer?
    private var observers: [NSObjectProtocol] = []

    init() {
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let scroll = FollowingScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 500))
        let text = TranscriptTextView(frame: NSRect(origin: .zero, size: scroll.contentSize), textContainer: container)
        scrollView = scroll
        textView = text

        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.importsGraphics = false
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainerInset = NSSize(width: 20, height: 16)
        text.setAccessibilityLabel(String(localized: "Transcript"))

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = text
        scroll.onUserScroll = { [weak self] event in self?.userScrolled(event) }
        scroll.contentView.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSScrollView.didLiveScrollNotification, object: scroll, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.userScrolled(nil) }
            },
            center.addObserver(forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resized() }
            },
        ]
    }

    func show(_ doc: TranscriptDocument, query: String, startedAt: Date, jump: Int) {
        guard let layout = textView.layoutManager else { return }
        let newSession = startedAt != self.startedAt
        let newQuery = query != self.query
        self.startedAt = startedAt
        self.query = query
        if let cursor, NSMaxRange(cursor) <= storage.length { layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: cursor) }
        let changed = apply(doc, rebuild: newSession || newQuery)
        committedLength = doc.committedLength
        cursor = doc.cursor
        cursorShown = true
        textView.avatars = doc.avatars
        if changed { textView.needsDisplay = true }  // avatars sit outside the edited text's rects
        updateBlink()

        let jumped = jump != self.jump
        self.jump = jump
        let isFollowing = following?.wrappedValue ?? true
        if newSession {
            if !isFollowing { DispatchQueue.main.async { self.following?.wrappedValue = true } }
            scrollToEnd(animated: false)
        } else if newQuery {
            if !query.isEmpty { scrollToTop() } else if isFollowing { scrollToEnd(animated: false) }
        } else if jumped || (changed && isFollowing && query.isEmpty) {
            scrollToEnd(animated: true)
        }
    }

    func stop() {
        blink?.invalidate()
        blink = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    /// Replaces only what changed since the last finished turn, so a selection in earlier text survives new lines.
    private func apply(_ doc: TranscriptDocument, rebuild: Bool) -> Bool {
        if rebuild {
            storage.setAttributedString(doc.content)
            return true
        }
        let old = storage.mutableString
        let new = doc.content.mutableString
        if old.isEqual(to: new as String) { return false }
        let limit = min(committedLength, doc.committedLength, old.length, new.length)
        var start = 0
        while start < limit, old.character(at: start) == new.character(at: start) { start += 1 }
        // Redo the whole turn: a speaker's color depends on their full name, which may have just changed.
        if let turn = doc.avatars.last(where: { $0.location <= start }) { start = turn.location }
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: start, length: old.length - start),
                                  with: doc.content.attributedSubstring(from: NSRange(location: start, length: new.length - start)))
        storage.endEditing()
        return true
    }

    /// Scroll offset that shows the end of the text.
    private var endOffset: CGFloat {
        let insets = scrollView.contentInsets
        return max(-insets.top, textView.frame.height + insets.bottom - scrollView.contentView.bounds.height)
    }

    private func scrollToEnd(animated: Bool) {
        if let layout = textView.layoutManager, let container = textView.textContainer { layout.ensureLayout(for: container) }
        textView.sizeToFit()
        let clip = scrollView.contentView
        let target = NSPoint(x: 0, y: endOffset)
        guard abs(clip.bounds.origin.y - target.y) > 0.5 else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                clip.animator().setBoundsOrigin(target)
            }
        } else {
            clip.setBoundsOrigin(target)
        }
        scrollView.reflectScrolledClipView(clip)
    }

    private func scrollToTop() {
        let clip = scrollView.contentView
        clip.setBoundsOrigin(NSPoint(x: 0, y: -scrollView.contentInsets.top))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Scrolling up leaves the live line at once; following resumes once the user is back at the end.
    private func userScrolled(_ event: NSEvent?) {
        let clip = scrollView.contentView
        let scrollable = textView.frame.height + scrollView.contentInsets.bottom > clip.bounds.height
        let atEnd = clip.bounds.origin.y >= endOffset - 30
        let follow = !scrollable || (atEnd && (event?.scrollingDeltaY ?? 0) <= 0)
        if let following, following.wrappedValue != follow { following.wrappedValue = follow }
    }

    private func resized() {
        if following?.wrappedValue ?? true, query?.isEmpty ?? true { scrollToEnd(animated: false) }
    }

    private func updateBlink() {
        guard cursor != nil else {
            blink?.invalidate()
            blink = nil
            return
        }
        guard blink == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        blink = timer
    }

    private func tick() {
        guard let cursor, let layout = textView.layoutManager, NSMaxRange(cursor) <= storage.length else { return }
        cursorShown.toggle()
        if cursorShown {
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: cursor)
        } else {
            layout.addTemporaryAttribute(.foregroundColor, value: NSColor.clear, forCharacterRange: cursor)
        }
    }
}

/// Reports scrolling done by the user, as opposed to the view following the live line.
final class FollowingScrollView: NSScrollView {
    var onUserScroll: (NSEvent?) -> Void = { _ in }

    override func scrollWheel(with event: NSEvent) {
        if event.scrollingDeltaY > 0 {
            // Scrolling up: stop a follow animation that would pull the view back down.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                self.contentView.animator().setBoundsOrigin(self.contentView.bounds.origin)
            }
        }
        super.scrollWheel(with: event)
        onUserScroll(event)
    }
}

/// Read-only text view that draws each speaker's avatar in the left margin, next to their name.
final class TranscriptTextView: NSTextView {
    struct Avatar {
        let location: Int
        let name: String?
    }

    static let avatarSize: CGFloat = 28
    /// Avatar plus the gap before the text.
    static let gutter: CGFloat = 38
    var avatars: [Avatar] = []

    /// Plain text only: rich text would carry this window's colors (white text in dark mode) into other apps.
    /// Filtered from AppKit's own list: a hand-written `[.string]` declares the type but writes nothing.
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.writablePasteboardTypes.filter { $0 == .string || $0.rawValue == "NSStringPboardType" }
    }

    /// ⌘C writes the selected text as plain text, without the blinking block of the live line.
    override func copy(_ sender: Any?) {
        let text = string as NSString
        let selected = selectedRanges.map(\.rangeValue).filter { $0.length > 0 && NSMaxRange($0) <= text.length }
            .map { text.substring(with: $0) }.joined(separator: "\n")
            .replacingOccurrences(of: "\u{258D}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selected.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selected, forType: .string)
    }

    /// ⌘A selects the whole transcript, even before the text was clicked.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "a",
           let window, window.isKeyWindow,
           window.firstResponder === self || !(window.firstResponder is NSText) {
            window.makeFirstResponder(self)
            selectAll(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !avatars.isEmpty, let layout = layoutManager, let container = textContainer, let storage = textStorage else { return }
        let origin = textContainerOrigin
        let size = Self.avatarSize
        // A name's line can start up to one avatar height above the dirty rect.
        let band = NSRect(x: 0, y: dirtyRect.minY - origin.y - size, width: max(container.size.width, 1), height: dirtyRect.height + size)
        let chars = layout.characterRange(forGlyphRange: layout.glyphRange(forBoundingRect: band, in: container), actualGlyphRange: nil)
        var low = 0, high = avatars.count
        while low < high {
            let mid = (low + high) / 2
            if avatars[mid].location < chars.location { low = mid + 1 } else { high = mid }
        }
        for avatar in avatars[low...] {
            guard avatar.location <= NSMaxRange(chars), avatar.location < storage.length else { break }
            let line = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: avatar.location), effectiveRange: nil)
            let rect = NSRect(x: textContainerInset.width, y: origin.y + line.minY, width: size, height: size)
            if rect.intersects(dirtyRect) { Self.drawAvatar(avatar.name, in: rect) }
        }
    }

    static func speakerColor(_ name: String?) -> NSColor {
        name == nil ? .secondaryLabelColor : NSColor(SpeakerColor.of(name))
    }

    private static func drawAvatar(_ name: String?, in rect: NSRect) {
        let color = speakerColor(name)
        color.withAlphaComponent(0.18).setFill()
        NSBezierPath(ovalIn: rect).fill()
        let initials = (name ?? "").split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        if initials.isEmpty {
            let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular).applying(.init(paletteColors: [color]))
            guard let image = NSImage(systemSymbolName: "person.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
            let s = image.size
            image.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: color]
            let s = (initials as NSString).size(withAttributes: attributes)
            (initials as NSString).draw(at: NSPoint(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2), withAttributes: attributes)
        }
    }
}

/// The text of a list of turns plus the live line, and where each speaker's avatar goes.
@MainActor
final class TranscriptDocument {
    let content = NSMutableAttributedString()
    /// Length of the finished turns; the live line comes after them.
    private(set) var committedLength = 0
    private(set) var avatars: [TranscriptTextView.Avatar] = []
    /// The blinking block at the end of the live line.
    private(set) var cursor: NSRange?

    init(turns: [Turn], startedAt: Date, query: String, live: (String?, String)?) {
        for turn in turns {
            add(turn.speaker, detail: startedAt.addingTimeInterval(turn.start).formatted(date: .omitted, time: .shortened),
                text: turn.text, color: .labelColor, query: query)
        }
        committedLength = content.length
        if let live, !live.1.isEmpty {
            add(live.0, detail: String(localized: "speaking"), text: live.1 + " ", color: .secondaryLabelColor, query: "")
            cursor = NSRange(location: content.length, length: 1)
            content.append(NSAttributedString(string: "▍", attributes: [.font: Style.body, .foregroundColor: NSColor.controlAccentColor, .paragraphStyle: Style.line]))
        }
    }

    private func add(_ speaker: String?, detail: String, text: String, color: NSColor, query: String) {
        if content.length > 0 {
            content.append(NSAttributedString(string: "\n", attributes: [.font: Style.body, .paragraphStyle: Style.line]))
            content.append(NSAttributedString(string: "\n", attributes: [.font: Style.body, .paragraphStyle: Style.gap]))
        }
        avatars.append(.init(location: content.length, name: speaker))
        content.append(NSAttributedString(string: speaker ?? String(localized: "Speaker"),
                                          attributes: [.font: Style.name, .foregroundColor: TranscriptTextView.speakerColor(speaker), .paragraphStyle: Style.header]))
        content.append(NSAttributedString(string: "  \(detail)\n",
                                          attributes: [.font: Style.detail, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: Style.header]))
        let line = NSMutableAttributedString(string: text, attributes: [.font: Style.body, .foregroundColor: color, .paragraphStyle: Style.line])
        if !query.isEmpty {
            let string = text as NSString
            var range = NSRange(location: 0, length: string.length)
            while true {
                let hit = string.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: range)
                guard hit.location != NSNotFound, hit.length > 0 else { break }
                line.addAttribute(.backgroundColor, value: Style.match, range: hit)
                range = NSRange(location: NSMaxRange(hit), length: string.length - NSMaxRange(hit))
            }
        }
        content.append(line)
    }
}

@MainActor
private enum Style {
    static let body = NSFont.preferredFont(forTextStyle: .body)
    static let name = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .semibold)
    static let detail = NSFont.monospacedDigitSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
    static let match = NSColor.systemYellow.withAlphaComponent(0.45)
    static let header = paragraph(spacingAfter: 3)
    static let line = paragraph(lineSpacing: 3)
    /// Empty line between turns: with the line spacing above it, 18 pt.
    static let gap = paragraph(lineHeight: 15)

    private static func paragraph(lineSpacing: CGFloat = 0, spacingAfter: CGFloat = 0, lineHeight: CGFloat? = nil) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = TranscriptTextView.gutter
        style.headIndent = TranscriptTextView.gutter
        style.lineSpacing = lineSpacing
        style.paragraphSpacing = spacingAfter
        if let lineHeight {
            style.minimumLineHeight = lineHeight
            style.maximumLineHeight = lineHeight
        }
        return style
    }
}
