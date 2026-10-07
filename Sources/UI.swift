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
                    .font(.system(size: 11, weight: .semibold)).tracking(0.5).foregroundStyle(.secondary)
                Spacer()
                Text("Claude").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.top, 12)

            Group {
                if issue.hasFix {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { old; arrow; fix }
                        VStack(alignment: .leading, spacing: 6) { old; fix }
                    }
                } else {
                    Text(issue.original).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                }
            }
            .padding(.horizontal, 14).padding(.top, 10)

            Text(issue.reason)
                .font(.system(size: 12)).foregroundStyle(.secondary)
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
                        Text("Fix all \(total)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 6).padding(.vertical, 4).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
        .frame(width: 330)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
    }

    var old: some View {
        Text(issue.original).font(.system(size: 15)).strikethrough().foregroundStyle(.secondary).lineLimit(3)
    }
    var arrow: some View {
        Image(systemName: "arrow.right").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
    }
    var fix: some View {
        Button(action: accept) {
            Text(issue.suggestion).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(3)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor))
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
            .font(.system(size: 12))
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: corner badge

struct BadgeView: View {
    let count: Int
    let checking: Bool
    let tidy: Bool
    let fixAll: () -> Void
    let tidyUp: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if tidy {
                Button(action: tidyUp) {
                    Text("Tidy up").font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 9).frame(height: 24)
                        .background(Capsule().fill(Color(nsColor: Kind.tidy.color)))
                }.buttonStyle(.plain)
            }
            if count > 0 || checking || !tidy { fixButton }
        }
        .fixedSize()                        // never squeeze "Fix all" into "Fix..."
        .padding(3)
    }

    var fixButton: some View {
        Button(action: fixAll) {
            HStack(spacing: 5) {
                if count > 0 {
                    Text("\(count)").font(.system(size: 12, weight: .bold))
                    Text("Fix all").font(.system(size: 11, weight: .medium))
                } else {
                    ProgressView().controlSize(.mini).tint(.white)
                    Text("Checking").font(.system(size: 11, weight: .medium))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 9).frame(height: 24)
            .background(Capsule().fill(count > 0 ? Color(nsColor: Kind.spelling.color) : Color.gray.opacity(0.85)))
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
    }
}

// MARK: tidy-up card

struct TidyCardView: View {
    let tidy: Tidy
    let warn: Bool
    let replace: () -> Void
    let ignore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(Color(nsColor: Kind.tidy.color)).frame(width: 8, height: 8)
                Text("TIDY UP").font(.system(size: 11, weight: .semibold)).tracking(0.5).foregroundStyle(.secondary)
                Spacer()
                Text("Claude").font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.top, 12)
            if !tidy.summary.isEmpty {
                Text(tidy.summary).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 14).padding(.top, 6)
            }
            ScrollView {
                Text(previewText).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxHeight: 300)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            .padding(.horizontal, 10).padding(.top, 10)
            if warn {
                Text("Replaces the whole message. Links and @mentions become plain text.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 14).padding(.top, 8)
            }
            Divider().padding(.top, 10)
            HStack(spacing: 2) {
                Button(action: replace) {
                    Text("Replace").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor))
                }.buttonStyle(.plain)
                FootButton(title: "Ignore", key: nil, action: ignore)
                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
        }
        .frame(width: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
    }

    /// Bold phrases shown bold.
    var previewText: AttributedString {
        var a = AttributedString(tidy.preview)
        for b in tidy.bold {
            if let r = a.range(of: b) { a[r].inlinePresentationIntent = .stronglyEmphasized }
        }
        return a
    }
}

