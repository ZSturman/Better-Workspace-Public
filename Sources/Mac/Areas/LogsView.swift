import SwiftUI
import BetterWorkspaceCore

/// Logs: 22 `YYYY-MM-DD` day folders plus a `workspace-watcher` service directory,
/// holding 147 line-oriented `.log` files in `[timestamp] [LEVEL] [subsystem] message`
/// form.
///
/// Nothing card-shaped or grid-shaped helps here. This is a three-pane log viewer:
/// days on the left, that day's files next, and the tail of the selected file in a
/// monospaced pane with level highlighting and a live filter.
struct LogsView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedDay: WorkspaceItem?
    @State private var dayFiles: [WorkspaceItem] = []
    @State private var selectedFile: WorkspaceItem?
    @State private var lines: [LogLine] = []
    @State private var filter = ""
    @State private var levelFilter: String?
    /// Remembered: someone who reads the work log goes back to it.
    @AppStorage("logsMode", store: TestIsolation.defaults) private var mode: Mode = .files

    /// The files other tools write, or the work log the background service drafts from
    /// observed sessions. Both are a history of the Workspace; only one is files.
    enum Mode: String, CaseIterable, Identifiable {
        case files = "Files"
        case workLog = "Work Log"
        var id: String { rawValue }
    }

    struct LogLine: Identifiable {
        let id: Int
        let text: String
        let level: String?
    }

    /// Newest day first — that's the one you want 95% of the time. Service folders
    /// such as `workspace-watcher` sort after the dated ones rather than winning on a
    /// plain reverse-alphabetical sort.
    private var days: [WorkspaceItem] {
        model.items(for: .logs).sorted { lhs, rhs in
            let l = Self.isDateFolder(lhs.name), r = Self.isDateFolder(rhs.name)
            if l != r { return l }
            return lhs.name > rhs.name
        }
    }

    private static func isDateFolder(_ name: String) -> Bool {
        name.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    private var visibleLines: [LogLine] {
        var result = lines
        if let levelFilter { result = result.filter { $0.level == levelFilter } }
        if filter.isEmpty == false { result = result.filter { $0.text.localizedCaseInsensitiveContains(filter) } }
        return result
    }

    private var levelCounts: [(String, Int)] {
        var counts: [String: Int] = [:]
        for line in lines { if let level = line.level { counts[level, default: 0] += 1 } }
        return ["ERROR", "WARN", "WARNING", "INFO", "DEBUG"].compactMap { level in
            counts[level].map { (level, $0) }
        }
    }

    /// Not read yet, so an empty list here would be a false "nothing".
    private var showsLoading: Bool { days.isEmpty && model.isAwaitingFirstRead(of: .logs) }

    var body: some View {
        VStack(spacing: 0) {
            AreaHeader(title: "Logs", subtitle: model.headerSubtitle(for: .logs),
                       symbol: model.settings(for: .logs).symbol, count: showsLoading ? nil : days.count) {
                HStack(spacing: Theme.Space.snug) {
                if mode == .files, selectedFile != nil {
                    HStack(spacing: Theme.Space.tight) {
                        ForEach(levelCounts, id: \.0) { level, count in
                            Button {
                                levelFilter = (levelFilter == level) ? nil : level
                            } label: {
                                Text("\(level) \(count)")
                                    .font(.system(size: 10, weight: .medium))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(
                                        RoundedRectangle(cornerRadius: 4)
                                            .fill(levelFilter == level
                                                  ? Self.levelColor(level).opacity(0.35)
                                                  : Self.levelColor(level).opacity(0.14))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("logs.mode")
                }
            }
            Divider()

            if mode == .workLog {
                WorkLogList(entries: model.workLogs, coverage: model.workLogCoverage,
                            serviceReachable: model.watcherReachable != false,
                            loading: model.isAwaitingBackgroundService)
            } else if showsLoading {
                LoadingAreaState(title: "Loading logs…")
            } else if days.isEmpty {
                EmptyAreaState(symbol: "list.bullet.rectangle", title: "No logs", message: "No log folders found.")
            } else {
                // The day list is the timeline; a second rail of the same days above it
                // took 80 points of height to say "Now" and "Past".
                HSplitView {
                    dayList.frame(minWidth: 130, idealWidth: 150, maxWidth: 220)
                    fileList.frame(minWidth: 160, idealWidth: 220, maxWidth: 320)
                    logPane.frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: days.count) { if selectedDay == nil { await selectDay(days.first) } }
        // Other tools append to these files all day. Any change under Logs re-reads the
        // open day and the open file in place, so the tail is live rather than a
        // snapshot of the moment it was clicked.
        .task(id: model.revision(ofArea: WorkspaceArea.logs.directoryName)) { await reloadInPlace() }
    }

    private var dayList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(days) { day in
                    Button { Task { await selectDay(day) } } label: {
                        HStack(spacing: Theme.Space.tight) {
                            Text(day.name)
                                .font(.system(size: 12, design: day.name.first?.isNumber == true ? .monospaced : .default))
                            Spacer()
                            if let count = day.immediateChildCount, count > 0 {
                                Text("\(count)")
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, Theme.Space.snug)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(selectedDay?.id == day.id ? Color.accentColor.opacity(0.15) : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu { ItemContextMenu(item: day) }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(dayFiles) { file in
                    Button { Task { await selectFile(file) } } label: {
                        HStack(spacing: Theme.Space.tight) {
                            Image(systemName: file.isDirectory ? "folder" : "text.alignleft")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(file.name).font(.system(size: 11)).lineLimit(1)
                                Text(Format.bytes(file.byteSize))
                                    .font(.system(size: 9).monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, Theme.Space.snug)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(selectedFile?.id == file.id ? Color.accentColor.opacity(0.15) : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.2))
    }

    @ViewBuilder
    private var logPane: some View {
        if selectedFile == nil {
            EmptyAreaState(symbol: "text.alignleft", title: "Select a log", message: "Pick a file to read its tail.")
        } else {
            VStack(spacing: 0) {
                HStack(spacing: Theme.Space.tight) {
                    Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10)).foregroundStyle(.secondary)
                    TextField("Filter lines", text: $filter)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                    Text("\(visibleLines.count)/\(lines.count)")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button {
                        Task { await selectFile(selectedFile) }
                    } label: { Image(systemName: "arrow.clockwise").font(.system(size: 10)) }
                        .buttonStyle(.plain)
                        .help("Re-read the tail of this log")
                }
                .padding(.horizontal, Theme.Space.snug)
                .padding(.vertical, 5)
                Divider()

                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleLines) { line in
                            Text(line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(line.level.map { Self.levelColor($0) } ?? Color.primary)
                                .textSelection(.enabled)
                                .lineLimit(1)
                                // Without this the line is forced to the container's
                                // width and clipped mid-word, so the horizontal scroll
                                // had nothing to reveal.
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, Theme.Space.snug)
                                .padding(.vertical, 1)
                        }
                    }
                    .padding(.vertical, Theme.Space.tight)
                }
            }
        }
    }

    @MainActor
    private func selectDay(_ day: WorkspaceItem?) async {
        selectedDay = day
        model.selectedItem = day
        selectedFile = nil
        lines = []
        guard let day, day.isDirectory else { dayFiles = []; return }
        let files = (try? await model.fs.items(inDirectory: day.url)) ?? []
        // A slower read for a day clicked earlier must not land on a later one.
        guard selectedDay?.id == day.id else { return }
        dayFiles = files
        // Prefer an actual log over whatever happens to sort first — a service folder
        // also holds databases and JSON snapshots.
        let first = dayFiles.first(where: { $0.kind == .log })
            ?? dayFiles.first(where: { $0.isDirectory == false })
        if let first { await selectFile(first) }
    }

    @MainActor
    private func selectFile(_ file: WorkspaceItem?) async {
        selectedFile = file
        levelFilter = nil
        guard let file else { lines = []; return }
        let fresh = await Self.tail(of: file, fs: model.fs)
        // Clicking a large log then a small one used to show the large one's lines
        // under the small one's name, whenever the first read finished second.
        guard selectedFile?.id == file.id else { return }
        lines = fresh
    }

    /// Re-reads the open day and file without resetting what someone chose: the same
    /// file stays open and the level filter stays applied.
    @MainActor
    private func reloadInPlace() async {
        guard let day = selectedDay, day.isDirectory else { return }
        guard let files = try? await model.fs.items(inDirectory: day.url), selectedDay?.id == day.id else { return }
        dayFiles = files
        guard let file = selectedFile else { return }
        guard files.contains(where: { $0.id == file.id }) else {
            // Rotated or removed: say so by clearing, rather than keep showing old lines.
            selectedFile = nil
            lines = []
            return
        }
        let fresh = await Self.tail(of: file, fs: model.fs)
        guard selectedFile?.id == file.id else { return }
        lines = fresh
    }

    private static func tail(of file: WorkspaceItem, fs: FilesystemService) async -> [LogLine] {
        let text = await fs.readTail(at: file.url) ?? ""
        return text.components(separatedBy: .newlines)
            .filter { $0.isEmpty == false }
            .enumerated()
            .map { LogLine(id: $0.offset, text: $0.element, level: detectLevel($0.element)) }
    }

    private static func detectLevel(_ line: String) -> String? {
        for level in ["ERROR", "WARNING", "WARN", "INFO", "DEBUG", "TRACE"] {
            if line.contains("[\(level)]") { return level }
        }
        return nil
    }

    private static func levelColor(_ level: String) -> Color {
        switch level {
        case "ERROR": return Color(red: 0.86, green: 0.32, blue: 0.32)
        case "WARN", "WARNING": return Color(red: 0.86, green: 0.62, blue: 0.22)
        case "DEBUG", "TRACE": return Color.secondary
        default: return Color.primary.opacity(0.85)
        }
    }
}

/// The work log, as the background service drafts it: one entry per project per day,
/// built from the sessions it observed. Read-only here — the service owns the drafts,
/// and sending them to Notion stays optional and off. Entries rebuilt from the surviving
/// journals say so, and a day with no surviving evidence is shown as exactly that.
private struct WorkLogList: View {
    let entries: [WorkLogEntry]
    let coverage: [String: WorkLogDayCoverage]
    let serviceReachable: Bool
    /// The first read of the service has not finished; no entries yet means nothing.
    let loading: Bool

    private var days: [(day: String, entries: [WorkLogEntry])] {
        var grouped = Dictionary(grouping: entries, by: \.dateKey)
        for (day, info) in coverage where info.status == .noEvidence && grouped[day] == nil {
            grouped[day] = []
        }
        return grouped
            .map { ($0.key, $0.value.sorted { $0.activeMinutes > $1.activeMinutes }) }
            .sorted { $0.day > $1.day }
    }

    var body: some View {
        if entries.isEmpty, loading {
            LoadingAreaState(title: "Loading the work log…", message: "Asking the background service for recent entries.")
        } else if entries.isEmpty {
            EmptyAreaState(
                symbol: "clock.arrow.circlepath",
                title: "No work log yet",
                message: serviceReachable
                    ? "The background service drafts an entry for each project you work on each day."
                    : "The background service isn't running. Start it in Settings to keep a work log."
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.snug, pinnedViews: [.sectionHeaders]) {
                    ForEach(days, id: \.day) { day in
                        Section {
                            if day.entries.isEmpty {
                                Text("No evidence survives for this day, so nothing is filled in.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, Theme.Space.base)
                                    .accessibilityIdentifier("worklog.noEvidence.\(day.day)")
                            }
                            ForEach(day.entries) { entry in WorkLogRow(entry: entry) }
                        } header: {
                            HStack {
                                Text(day.day).font(.system(size: 11, weight: .semibold, design: .monospaced))
                                Spacer()
                                Text(Format.duration(seconds: day.entries.reduce(0) { $0 + $1.activeMinutes } * 60))
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, Theme.Space.base)
                            .padding(.vertical, 4)
                            .background(.regularMaterial)
                        }
                    }
                }
                .padding(.bottom, Theme.Space.base)
            }
        }
    }
}

private struct WorkLogRow: View {
    let entry: WorkLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.tight) {
                Text(entry.projectName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(Format.count(entry.sessionCount, singular: "session"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: Theme.Space.tight)
                if entry.isReconstructed {
                    Text(entry.isWhollyReconstructed ? "Reconstructed" : "\(entry.reconstructedSessionCount) reconstructed")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .help("Rebuilt from the filesystem and terminal journals, not observed live")
                }
                if entry.syncedToNotion {
                    Text("In Notion").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Text(Format.duration(seconds: entry.activeMinutes * 60))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let summary = entry.summary {
                Text(MarkdownInline.summary(summary)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
            } else if entry.files.isEmpty == false {
                Text(entry.files.prefix(4).map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
                    .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(.horizontal, Theme.Space.base)
        .accessibilityElement(children: .combine)
    }
}
