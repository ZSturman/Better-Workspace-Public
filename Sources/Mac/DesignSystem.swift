import SwiftUI
import BetterWorkspaceCore

/// One visual language across the Workspace's different layouts.
///
/// The areas deliberately do *not* share a layout, so coherence has to come from
/// somewhere else: identical type ramp, identical spacing scale, identical tag chips,
/// identical section headers, identical inspector.
enum Theme {

    enum Space {
        static let hair: CGFloat = 2
        static let tight: CGFloat = 6
        static let snug: CGFloat = 10
        static let base: CGFloat = 16
        static let loose: CGFloat = 24
        static let section: CGFloat = 32
    }

    enum Radius {
        static let chip: CGFloat = 5
        static let card: CGFloat = 10
        static let panel: CGFloat = 14
    }

    /// Eight tag colours. A tag's colour is derived from its name, so `AI` is the same
    /// hue in Ideas, Projects and the ingest inbox.
    static let tagPalette: [Color] = [
        Color(red: 0.38, green: 0.55, blue: 0.94),
        Color(red: 0.56, green: 0.44, blue: 0.89),
        Color(red: 0.86, green: 0.42, blue: 0.62),
        Color(red: 0.91, green: 0.50, blue: 0.32),
        Color(red: 0.82, green: 0.66, blue: 0.24),
        Color(red: 0.36, green: 0.68, blue: 0.47),
        Color(red: 0.30, green: 0.68, blue: 0.71),
        Color(red: 0.51, green: 0.55, blue: 0.62),
    ]

    static func tagColor(_ tag: Tag) -> Color {
        tagPalette[abs(tag.colorIndex) % tagPalette.count]
    }

    static func kindColor(_ kind: FileKind) -> Color {
        switch kind {
        case .folder: return Color(red: 0.36, green: 0.56, blue: 0.92)
        case .markdown, .document: return Color(red: 0.45, green: 0.50, blue: 0.58)
        case .image: return Color(red: 0.56, green: 0.44, blue: 0.89)
        case .video: return Color(red: 0.86, green: 0.42, blue: 0.62)
        case .audio: return Color(red: 0.91, green: 0.50, blue: 0.32)
        case .spreadsheet: return Color(red: 0.24, green: 0.62, blue: 0.42)
        case .archive: return Color(red: 0.62, green: 0.52, blue: 0.36)
        case .code: return Color(red: 0.30, green: 0.68, blue: 0.71)
        case .model3D: return Color(red: 0.72, green: 0.58, blue: 0.26)
        case .log: return Color(red: 0.51, green: 0.55, blue: 0.62)
        case .data: return Color(red: 0.42, green: 0.48, blue: 0.72)
        case .other: return Color.secondary
        }
    }
}

/// The header every workspace section uses, so distinct bodies still read as one app.
struct AreaHeader<Trailing: View>: View {
    let title: String
    /// Shown only when there is something worth saying.
    let subtitle: String?
    let symbol: String
    var count: Int?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.snug) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Theme.Space.tight) {
                    Text(title)
                        .font(.system(size: 20, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .accessibilityIdentifier("area.title")
                    if let count {
                        Text("\(count)")
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.14), in: Capsule())
                            .fixedSize()
                    }
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            // Without this the trailing controls win the width negotiation and squeeze
            // the title to nothing — at 820pt the subtitle rendered one character per
            // line down the left edge.
            .layoutPriority(2)
            Spacer(minLength: Theme.Space.tight)
            trailing
                .layoutPriority(1)
        }
        .padding(.horizontal, Theme.Space.base)
        .padding(.top, Theme.Space.snug)
        .padding(.bottom, Theme.Space.snug)
    }
}

extension AreaHeader where Trailing == EmptyView {
    init(title: String, subtitle: String?, symbol: String, count: Int? = nil) {
        self.init(title: title, subtitle: subtitle, symbol: symbol, count: count, trailing: { EmptyView() })
    }
}

/// Search belongs to the area, not to the window.
///
/// Originally this was `.searchable(placement: .toolbar)`, but switching between areas
/// that do and don't declare one made SwiftUI reinsert a toolbar item with an identifier
/// the toolbar already held, and AppKit raised `NSInternalInconsistencyException` from
/// `-[NSToolbar _insertNewItemWithItemIdentifier:atIndex:]`. An inline field also keeps
/// the search next to the list it filters.
struct InlineSearchField: View {
    @Binding var text: String
    var prompt: String
    var width: CGFloat = 200

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if text.isEmpty == false {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .frame(minWidth: 96, idealWidth: width, maxWidth: width)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// Shown in place of an empty state while the data it would describe is still being
/// read. An empty list before the first read is "not known yet", never "nothing here".
struct LoadingAreaState: View {
    let title: String
    var message: String? = nil

    var body: some View {
        VStack(spacing: Theme.Space.snug) {
            ProgressView().controlSize(.regular)
            Text(title).font(.headline)
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.section)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("loadingState")
    }
}

/// The inline form, for a section inside a larger page.
struct LoadingLabel: View {
    let text: String

    var body: some View {
        HStack(spacing: Theme.Space.snug) {
            ProgressView().controlSize(.small)
            Text(text)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.vertical, Theme.Space.tight)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("loadingLabel")
    }
}

struct EmptyAreaState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: Theme.Space.snug) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.section)
    }
}
