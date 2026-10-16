import SwiftUI
import AppKit
import BetterWorkspaceCore

/// A publishing queue over portable `.social.md` files. The view has no hidden state:
/// a post can always be opened in a text editor, copied exactly as it will be posted,
/// or followed to the URL a platform confirmed.
struct SocialPostsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var filter: SocialPostStatus?

    private var posts: [SocialPost] {
        model.socialPosts.filter { post in
            (filter == nil || post.status == filter)
                && (query.isEmpty || post.title.localizedCaseInsensitiveContains(query)
                    || post.preview.localizedCaseInsensitiveContains(query))
        }
    }

    /// Not read yet, so an empty list here would be a false "nothing".
    private var showsLoading: Bool { model.socialPosts.isEmpty && model.socialPostsLoaded == false && model.workspaceAvailable }

    var body: some View {
        VStack(spacing: 0) {
            AreaHeader(title: "Social Posts", subtitle: model.headerSubtitle(for: .socialPosts),
                       symbol: model.settings(for: .socialPosts).symbol, count: showsLoading ? nil : model.socialPosts.count) {
                HStack(spacing: Theme.Space.tight) {
                    Button { Task { await model.refreshSocialPosts() } } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .labelStyle(.iconOnly)
                    .help("Re-read social-post files from the Workspace")
                    Button { model.revealInFinder(model.workspace.url(for: .socialPosts)) } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .labelStyle(.iconOnly)
                    .help("Show Social Posts in Finder")
                }
            }
            Divider()
            controls
            Divider()

            if showsLoading {
                LoadingAreaState(title: "Loading social posts…")
            } else if model.socialPosts.isEmpty {
                EmptyAreaState(symbol: "text.bubble", title: "No social posts yet",
                               message: "In Settings → Notion, check the Social Posts import before creating files. Each imported post stays as an ordinary Markdown file here.")
            } else if posts.isEmpty {
                EmptyAreaState(symbol: "line.3.horizontal.decrease.circle", title: "No matching posts",
                               message: "Change the status filter or search text to see posts.")
            } else {
                ScrollView {
                    LazyVStack(spacing: Theme.Space.snug) {
                        ForEach(posts) { post in SocialPostCard(post: post) }
                    }
                    .padding(Theme.Space.base)
                }
            }
        }
        .task(id: model.revision(ofArea: WorkspaceArea.socialPosts.directoryName)) { @MainActor in
            await model.refreshSocialPosts()
        }
    }

    private var controls: some View {
        HStack(spacing: Theme.Space.snug) {
            TextField("Search posts", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
            Menu {
                Button("All statuses") { filter = nil }
                Divider()
                ForEach(SocialPostStatus.allCases) { status in
                    Button { filter = status } label: {
                        Label(status.displayName, systemImage: status.symbolName)
                    }
                }
            } label: {
                Label(filter?.displayName ?? "All statuses", systemImage: filter?.symbolName ?? "line.3.horizontal.decrease.circle")
            }
            Spacer()
            Text(summary).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, Theme.Space.base)
        .padding(.vertical, Theme.Space.snug)
    }

    private var summary: String {
        let scheduled = model.socialPosts.filter { $0.status == .scheduled }.count
        let published = model.socialPosts.filter { $0.status == .posted }.count
        return "\(scheduled) scheduled · \(published) published"
    }
}

private struct SocialPostCard: View {
    @Environment(AppModel.self) private var model
    let post: SocialPost

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            HStack(alignment: .top, spacing: Theme.Space.snug) {
                Image(systemName: post.status.symbolName)
                    .foregroundStyle(color(for: post.status))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(post.title).font(.system(size: 15, weight: .semibold))
                    HStack(spacing: 5) {
                        Text(post.status.displayName)
                        if post.platforms.isEmpty == false { Text("· \(post.platforms.joined(separator: ", "))") }
                        if let scheduled = post.scheduledAt { Text("· \(scheduled.formatted(date: .abbreviated, time: .shortened))") }
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if post.status == .posted { Text("Published").font(.system(size: 11, weight: .medium)).foregroundStyle(.green) }
            }

            if post.preview.isEmpty == false {
                Text(MarkdownInline.summary(post.preview))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if let error = post.postingError, error.isEmpty == false {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2)
            }
            HStack(spacing: Theme.Space.tight) {
                if post.linkedInContent.isEmpty == false {
                    Button("Copy LinkedIn") { copy(post.linkedInContent) }.font(.system(size: 11))
                }
                if post.blueskyContent.isEmpty == false {
                    Button("Copy Bluesky") { copy(post.blueskyContent) }.font(.system(size: 11))
                }
                Button("Edit") { model.open(post.url) }.font(.system(size: 11))
                Button("Reveal") { model.revealInFinder(post.url) }.font(.system(size: 11))
                Spacer()
                if let linkedIn = post.linkedInURL { Link("LinkedIn", destination: linkedIn).font(.system(size: 11)) }
                if let bluesky = post.blueskyURL { Link("Bluesky", destination: bluesky).font(.system(size: 11)) }
                if let source = post.sourceURL { Link("Notion", destination: source).font(.system(size: 11)) }
            }
        }
        .padding(Theme.Space.base)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.panel).strokeBorder(Color.secondary.opacity(0.15)))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model.statusMessage = "Copied \(post.title)"
    }

    private func color(for status: SocialPostStatus) -> Color {
        switch status {
        case .posted: return .green
        case .scheduled: return .purple
        case .ready: return .blue
        case .review: return .orange
        case .error: return .red
        case .draft: return .secondary
        }
    }
}
