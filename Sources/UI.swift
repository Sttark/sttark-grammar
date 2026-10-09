import AppKit
import SwiftUI

/// Floating window that never takes focus away from the app you are typing in.
func makePanel(mouse: Bool) -> NSPanel {
    let p = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
    p.isFloatingPanel = true
    p.level = mouse ? .popUpMenu : .floating
    p.hidesOnDeactivate = false
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = mouse
    p.ignoresMouseEvents = !mouse
    p.becomesKeyOnlyIfNeeded = true
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    return p
}

final class ClickThroughHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: underlines

final class UnderlineView: NSView {
    var marks: [(rects: [CGRect], color: NSColor, hot: Bool)] = [] { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        for m in marks {
            for r in m.rects {
                if m.hot {
                    m.color.withAlphaComponent(0.16).setFill()
                    NSBezierPath(roundedRect: r.insetBy(dx: -1, dy: 0), xRadius: 3, yRadius: 3).fill()
                }
                m.color.setFill()
                let line = CGRect(x: r.minX, y: r.minY - 1.5, width: r.width, height: 2.5)
                NSBezierPath(roundedRect: line, xRadius: 1.25, yRadius: 1.25).fill()
            }
        }
    }
}

// MARK: hover card

struct CardView: View {
    let issue: Issue
    let total: Int
    let accept: () -> Void
    let ignore: () -> Void
    let addWord: () -> Void
    let fixAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(Color(nsColor: issue.kind.color)).frame(width: 8, height: 8)
                Text(issue.kind.label.uppercased())
                    .font(.brand(11, .semibold)).tracking(0.5).foregroundStyle(.secondary)
                Spacer()
                Text("Claude").font(.brand(10)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.top, 12)

            Group {
                if issue.hasFix {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { old; arrow; fix }
                        VStack(alignment: .leading, spacing: 6) { old; fix }
                    }
                } else {
                    Text(issue.original).font(.brand(15, .semibold)).lineLimit(2)
                }
            }
            .padding(.horizontal, 14).padding(.top, 10)

            Text(issue.reason)
                .font(.brand(12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 12)

            Divider()
            HStack(spacing: 2) {
                if issue.hasFix { FootButton(title: "Accept", key: "Tab", action: accept) }
                FootButton(title: "Ignore", key: "Esc", action: ignore)
                if issue.kind == .spelling { FootButton(title: "Add to dictionary", key: nil, action: addWord) }
                Spacer(minLength: 4)
                if total > 1 {
                    Button(action: fixAll) {
                        Text("Fix all \(total)").font(.brand(12, .semibold)).foregroundStyle(Color(nsColor: Brand.greenText))
                            .padding(.horizontal, 6).padding(.vertical, 4).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
        .frame(width: 360)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
    }

    var old: some View {
        Text(issue.original).font(.brand(15)).strikethrough().foregroundStyle(.secondary).lineLimit(3)
    }
    var arrow: some View {
        Image(systemName: "arrow.right").font(.brand(12, .medium)).foregroundStyle(.secondary)
    }
    var fix: some View {
        Button(action: accept) {
            Text(issue.suggestion).font(.brand(14, .semibold)).foregroundStyle(.white).lineLimit(3)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: Brand.green)))
        }.buttonStyle(.plain)
    }
}

struct FootButton: View {
    let title: String
    let key: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).foregroundStyle(.primary)
                if let key { Text(key).foregroundStyle(.tertiary) }
            }
            .font(.brand(12))
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: corner badge

/// The one small round dot (12 px) in the box's corner, like Grammarly's: gray and spinning while checking, red with the
/// number of word fixes, blue when there's a tidy-up, red with a blue corner when there are both.
struct DotView: View {
    let count: Int
    let checking: Bool
    let tidy: Bool
    let click: () -> Void

    var body: some View {
        Button(action: click) {
            ZStack(alignment: .topTrailing) {
                Circle().fill(fill).frame(width: 12, height: 12)
                    .overlay {
                        if count > 0 {
                            Text(count > 99 ? "99+" : "\(count)").font(.system(size: count > 9 ? 5.5 : 7.5, weight: .bold)).foregroundStyle(.white)
                        } else if tidy {
                            Image(systemName: "wand.and.stars").font(.brand(6, .bold)).foregroundStyle(.white)
                        } else {
                            Spinner()
                        }
                    }
                if count > 0 && tidy {
                    Circle().fill(Color(nsColor: Kind.tidy.color)).frame(width: 5, height: 5).offset(x: 1.5, y: -1.5)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(3)
    }

    var fill: Color {
        if count > 0 { return Color(nsColor: Kind.spelling.color) }
        if tidy { return Color(nsColor: Kind.tidy.color) }
        return Color.gray.opacity(0.85)
    }
}

/// A small white arc that turns, for a dot too small for the system spinner.
struct Spinner: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            Circle().trim(from: 0, to: 0.7).stroke(Color.white, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
                .frame(width: 6.5, height: 6.5)
                .rotationEffect(.degrees(ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360))
        }
    }
}

/// What hovering the dot shows: Fix all and Tidy up, one click each, with the tidied message to look at.
struct DotCardView: View {
    let count: Int
    let checking: Bool
    let tidy: Tidy?
    let warn: Bool
    let fixAll: () -> Void
    let tidyUp: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if count > 0 {
                row(color: Kind.spelling.color, title: "\(count) \(count == 1 ? "fix" : "fixes")", detail: "Spelling, grammar and capitals",
                    button: "Fix all", main: true, action: fixAll)
            }
            if count > 0 && tidy != nil { Divider() }
            if let t = tidy {
                row(color: Kind.tidy.color, title: "Tidy up", detail: t.summary, button: "Tidy up", main: count == 0, action: tidyUp)
                // as tall as the message, and only scrolls when it's longer than the card has room for
                ViewThatFits(in: .vertical) {
                    previewText(t)
                    ScrollView { previewText(t) }
                }
                .frame(maxHeight: 220)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                .padding(.horizontal, 10).padding(.bottom, warn ? 4 : 10)
                if warn {
                    Text("Links and @mentions become plain text. Command-Z undoes it.")
                        .font(.brand(10.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 12).padding(.bottom, 10)
                }
            }
            if count == 0 && tidy == nil {
                Text(checking ? "Checking…" : "Nothing to fix").font(.brand(12)).foregroundStyle(.secondary).padding(12)
            }
        }
        .frame(width: 340)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
    }

    func row(color: NSColor, title: String, detail: String, button: String, main: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 9) {
            Circle().fill(Color(nsColor: color)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.brand(13, .semibold))
                if !detail.isEmpty {
                    Text(detail).font(.brand(11)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            Button(action: action) {
                // the main action is Sttark green; any other is an outline in the text color
                Text(button).font(.brand(12, .semibold)).foregroundStyle(main ? Color.white : Color.primary)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(main ? Color(nsColor: Brand.green) : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary, lineWidth: main ? 0 : 1))
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    func previewText(_ t: Tidy) -> some View {
        Text(preview(t)).font(.brand(12)).frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Bold phrases shown bold.
    func preview(_ t: Tidy) -> AttributedString {
        var a = AttributedString(t.preview)
        for b in t.bold { if let r = a.range(of: b) { a[r].inlinePresentationIntent = .stronglyEmphasized } }
        return a
    }
}


