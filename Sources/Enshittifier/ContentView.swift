import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    @State private var installInFlight = false
    @State private var installProgress: InstallProgress?
    @State private var migrationProgress: MigrationProgress?
    @State private var resultAlert: ResultAlert?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var model = model

        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            detailWithFooter
                .navigationTitle(model.tab.rawValue)
                .navigationSubtitle(subtitle)
                .toolbar { toolbarContent }
        }
        .task {
            await runBackupMigration()
            await loadFonts()
            await loadRestoreFamilies()
        }
        .sheet(item: $installProgress) { progress in
            InstallProgressView(progress: progress)
        }
        .sheet(item: $migrationProgress) { progress in
            MigrationProgressView(progress: progress)
        }
        .alert(item: $resultAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        // Global keyboard shortcuts (sidebar tabs, focus search). Hidden
        // buttons attached to the root so they fire window-wide regardless
        // of focus.
        .background {
            VStack {
                Button("") { model.tab = .allFonts }
                    .keyboardShortcut("1", modifiers: .command)
                Button("") { model.tab = .unshittified }
                    .keyboardShortcut("2", modifiers: .command)
                Button("") { model.tab = .enshittified }
                    .keyboardShortcut("3", modifiers: .command)
                Button("") { model.tab = .restoreOriginals }
                    .keyboardShortcut("4", modifiers: .command)
                Button("") { searchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
            }
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        @Bindable var model = model

        List(selection: $model.tab) {
            Section("Library") {
                Label("All Fonts", systemImage: AppModel.Tab.allFonts.systemImage)
                    .badge(badge(for: .allFonts))
                    .tag(AppModel.Tab.allFonts)
                Label("Un-shittified", systemImage: AppModel.Tab.unshittified.systemImage)
                    .badge(badge(for: .unshittified))
                    .tag(AppModel.Tab.unshittified)
                Label {
                    Text("Enshittified")
                } icon: {
                    PoopGlyph(size: 16, tint: .primary)
                }
                .badge(badge(for: .enshittified))
                .tag(AppModel.Tab.enshittified)

                // Font Backups lives with the library but is set apart by a
                // divider — it's the restore surface, not a browse list.
                Divider()
                    .padding(.vertical, 2)

                Label("Font Backups", systemImage: AppModel.Tab.restoreOriginals.systemImage)
                    .badge(badge(for: .restoreOriginals))
                    .tag(AppModel.Tab.restoreOriginals)
            }
        }
        .listStyle(.sidebar)
    }

    private func badge(for tab: AppModel.Tab) -> Int {
        switch tab {
        case .allFonts: return model.families.count
        case .unshittified:
            return model.families.filter { !model.isFamilyFullyPatched($0) }.count
        case .enshittified:
            return model.families.filter { model.isFamilyPartiallyPatched($0) }.count
        case .restoreOriginals: return model.restoreFamilies.count
        }
    }

    // MARK: - Detail + footer

    @ViewBuilder
    private var detailWithFooter: some View {
        VStack(spacing: 0) {
            // Restore tab uses a separate data model (RestoreFamily) that
            // doesn't carry activation/location state, so the FilterBar's
            // chips don't apply there — hide the bar entirely.
            if model.showFilterBar && model.tab != .restoreOriginals {
                FilterBar()
                Divider()
            }

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            footer
                .background(.bar)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        @Bindable var model = model

        if model.tab != .restoreOriginals {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.showFilterBar.toggle()
                } label: {
                    Label("Filters", systemImage: filterIcon)
                }
                .help(model.showFilterBar ? "Hide filters" : "Show filters")
            }
        }

        ToolbarItem(placement: .primaryAction) {
            Picker("View", selection: $model.viewMode) {
                ForEach(AppModel.ViewMode.allCases) { m in
                    Image(systemName: m.systemImage).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .help("Switch between grid and list view")
        }

        ToolbarItem(placement: .primaryAction) {
            ToolbarPill {
                HStack(spacing: 6) {
                    Image(systemName: "textformat.size.smaller")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Slider(value: $model.tileSize, in: 128...260)
                        .controlSize(.small)
                        .frame(width: 110)
                    Image(systemName: "textformat.size.larger")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
            .help("Preview size")
        }

        // Break Tahoe's auto-grouping so the search field renders as its
        // own pill rather than sharing a background with the size slider.
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }

        ToolbarItem(placement: .primaryAction) {
            ToolbarPill {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    TextField("Search", text: $model.searchQuery)
                        .textFieldStyle(.plain)
                        .frame(width: 160)
                        .focused($searchFocused)
                    if !model.searchQuery.isEmpty {
                        Button {
                            model.searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .fixedSize()
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.tab {
        case .allFonts, .unshittified, .enshittified:
            switch model.loadState {
            case .idle, .loading:
                ContentUnavailableView {
                    Label("Scanning fonts", systemImage: "magnifyingglass")
                } description: {
                    ProgressView().controlSize(.small).padding(.top, 6)
                }
            case .loaded:
                if model.filteredFamilies.isEmpty {
                    if model.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                        emptyState(for: model.tab)
                    } else {
                        ContentUnavailableView.search(text: model.searchQuery)
                    }
                } else {
                    FamilyGridView(families: model.filteredFamilies)
                }
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn\u{2019}t load fonts", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                }
            }
        case .restoreOriginals:
            if model.restoreFamilies.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("Nothing to restore")
                    } icon: {
                        PoopGlyph(size: 32, tint: .secondary)
                    }
                } description: {
                    Text("Patch some fonts first \u{2014} they\u{2019}ll show up here ready to restore.")
                }
            } else if model.filteredRestoreFamilies.isEmpty {
                ContentUnavailableView.search(text: model.searchQuery)
            } else {
                RestoreGridView(families: model.filteredRestoreFamilies)
            }
        }
    }

    @ViewBuilder
    private func emptyState(for tab: AppModel.Tab) -> some View {
        switch tab {
        case .unshittified:
            ContentUnavailableView {
                Label("Nothing here", systemImage: "checkmark.seal")
            } description: {
                Text("Every font has been enshittified. Head to Restore Originals to bring them back.")
            }
        case .enshittified:
            ContentUnavailableView {
                Label {
                    Text("Nothing enshittified yet")
                } icon: {
                    PoopGlyph(size: 32, tint: .secondary)
                }
            } description: {
                Text("Patched fonts will show up here once you enshittify some.")
            }
        default:
            ContentUnavailableView {
                Label("Nothing here", systemImage: "checkmark.seal")
            } description: {
                Text("No fonts found.")
            }
        }
    }

    // MARK: - Footer (bottom action bar)

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 8) {
            Text(footerSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            Button {
                selectAll()
            } label: {
                Text("Select All")
                    .frame(height: 24)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!hasAnyItems)
            .keyboardShortcut("a", modifiers: [.command])

            Button {
                selectNone()
            } label: {
                Text("Select None")
                    .frame(height: 24)
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!hasAnySelection)
            .keyboardShortcut("a", modifiers: [.command, .shift])

            Button(action: { Task { await primaryAction() } }) {
                HStack(spacing: 8) {
                    primaryActionIconView
                        // The icon uses an explicit white fill that won't
                        // dim with the button the way the text label does,
                        // so fade it manually to match the disabled state.
                        .opacity(primaryButtonDisabled ? 0.4 : 1)
                    Text(primaryActionLabel)
                        .fontWeight(.medium)
                }
                .frame(height: 24)
                .padding(.horizontal, 10)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(primaryActionTint)
            .keyboardShortcut(.defaultAction)
            .disabled(primaryButtonDisabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var primaryActionIconView: some View {
        if model.tab.selectsForRestore {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
        } else {
            PoopGlyph(size: 16, tint: .white)
        }
    }

    private var filterIcon: String {
        let hasActiveFilter = model.locationFilter != .all || model.activationFilter != .all
        if model.showFilterBar {
            return hasActiveFilter
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle"
        } else {
            return hasActiveFilter
                ? "line.3.horizontal.decrease.fill"
                : "line.3.horizontal.decrease"
        }
    }

    // MARK: - Derived

    private var subtitle: String {
        switch model.tab {
        case .allFonts:
            return countSummary(filtered: model.filteredFamilies.count, total: model.families.count)
        case .unshittified:
            let total = model.families.filter { !model.isFamilyFullyPatched($0) }.count
            return countSummary(filtered: model.filteredFamilies.count, total: total)
        case .enshittified:
            let total = model.families.filter { model.isFamilyPartiallyPatched($0) }.count
            return countSummary(filtered: model.filteredFamilies.count, total: total)
        case .restoreOriginals:
            let total = model.restoreFamilies.count
            let filtered = model.filteredRestoreFamilies.count
            return countSummary(filtered: filtered, total: total)
        }
    }

    private func countSummary(filtered: Int, total: Int) -> String {
        let noun = total == 1 ? "typeface" : "typefaces"
        return filtered == total ? "\(total) \(noun)" : "\(filtered) of \(total) \(noun)"
    }

    private var searchPrompt: String {
        switch model.tab {
        case .restoreOriginals: return "Search ready to restore"
        case .enshittified: return "Search enshittified"
        default: return "Search typefaces"
        }
    }

    private var footerSummary: String {
        switch model.tab {
        case .allFonts, .unshittified:
            let n = model.selectedStyles.count
            if n == 0 { return "Nothing selected" }
            let fams = Set(model.selectedStyles.map(\.familyName)).count
            return "\(fams) famil\(fams == 1 ? "y" : "ies") · \(n) style\(n == 1 ? "" : "s") selected"
        case .enshittified:
            let n = model.selectedStyles.count
            if n == 0 { return "Nothing selected" }
            let fams = Set(model.selectedStyles.map(\.familyName)).count
            return "\(fams) famil\(fams == 1 ? "y" : "ies") · \(n) style\(n == 1 ? "" : "s") selected"
        case .restoreOriginals:
            let selected = model.selectedRestoreEntries
            if selected.isEmpty { return "Nothing selected" }
            let fams = Set(selected.map(\.familyName)).count
            return "\(fams) famil\(fams == 1 ? "y" : "ies") · \(selected.count) style\(selected.count == 1 ? "" : "s") selected"
        }
    }

    private var primaryActionLabel: String {
        model.tab.selectsForRestore ? "Restore" : "Enshittify Selected"
    }

    private var primaryActionTint: Color {
        // Strong visual difference between the destructive Enshittify
        // action (warm warning) and the safe Restore action (calm purple).
        model.tab.selectsForRestore ? Self.restorePurple : .orange
    }

    /// Restore action accent — a deep violet that reads as deliberate and
    /// distinct from the orange Enshittify action while staying legible
    /// behind white text/icon on the prominent button.
    private static let restorePurple = Color(red: 0.45, green: 0.30, blue: 0.78)

    private var primaryButtonDisabled: Bool {
        primaryActionDisabled || installInFlight
    }

    private var primaryActionDisabled: Bool {
        switch model.tab {
        case .allFonts, .unshittified, .enshittified: return model.selectedStyles.isEmpty
        case .restoreOriginals: return model.selectedRestoreIDs.isEmpty
        }
    }

    private var hasAnyItems: Bool {
        switch model.tab {
        case .allFonts, .unshittified, .enshittified: return !model.filteredFamilies.isEmpty
        case .restoreOriginals: return !model.filteredRestoreFamilies.isEmpty
        }
    }

    private var hasAnySelection: Bool {
        switch model.tab {
        case .allFonts, .unshittified, .enshittified: return !model.selectedStyles.isEmpty
        case .restoreOriginals: return !model.selectedRestoreIDs.isEmpty
        }
    }

    private func selectAll() {
        switch model.tab {
        case .allFonts, .unshittified, .enshittified:
            // Only select within the current filtered view. On the
            // install tabs this skips fully-patched (locked) families;
            // on Enshittified everything shown is patched and selectable.
            let ids = Set(model.filteredFamilies
                .filter { model.tab == .enshittified || !model.isFamilyFullyPatched($0) }
                .flatMap { $0.styles.map(\.id) })
            model.selectedStyleIDs.formUnion(ids)
        case .restoreOriginals:
            let ids = Set(model.filteredRestoreFamilies.flatMap { $0.entries.map(\.id) })
            model.selectedRestoreIDs.formUnion(ids)
        }
    }

    private func selectNone() {
        switch model.tab {
        case .allFonts, .unshittified, .enshittified: model.selectedStyleIDs.removeAll()
        case .restoreOriginals: model.selectedRestoreIDs.removeAll()
        }
    }

    private func primaryAction() async {
        switch model.tab {
        case .allFonts, .unshittified: await runInstall()
        case .enshittified: await runRestoreFromEnshittified()
        case .restoreOriginals: await runRestore()
        }
    }


    // MARK: - Loading

    private func runBackupMigration() async {
        let progress = MigrationProgress()

        // Delay-present: only show the sheet if the migration is still
        // running after 300ms. The common case is an instant no-op (no
        // legacy folder, no stale manifest paths), and we don't want the
        // sheet to flash on every launch. If the migrator finishes first
        // we cancel the presenter before it ever sets the binding.
        let presenter = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            migrationProgress = progress
        }

        let outcome = await Task.detached(priority: .userInitiated) {
            BackupMigrator.migrateIfNeeded { label in
                Task { @MainActor in progress.phase = label }
            }
        }.value

        // Await the presenter so its (possible) "show the sheet" write
        // happens-before our dismiss — otherwise a presenter that wins the
        // race after we set nil would leave the sheet stuck open.
        presenter.cancel()
        await presenter.value
        await MainActor.run { migrationProgress = nil }

        guard !outcome.errors.isEmpty else { return }
        await MainActor.run {
            resultAlert = ResultAlert(
                title: "Couldn\u{2019}t move backups",
                message: outcome.errors.joined(separator: "\n")
            )
        }
    }

    private func loadFonts() async {
        model.loadState = .loading
        let families = await FontDiscovery.discover()
        await MainActor.run {
            model.families = families
            model.loadState = .loaded
        }
    }

    private func loadRestoreFamilies() async {
        let families = await Task.detached(priority: .userInitiated) {
            RestoreService.discover()
        }.value
        await MainActor.run {
            model.restoreFamilies = families
        }
    }

    // MARK: - Actions

    private func runInstall() async {
        let selected = model.selectedStyles
        guard !selected.isEmpty else { return }
        let affected = affectedFamilyIDs(forStyleIDs: Set(selected.map(\.id)))

        installInFlight = true
        defer { installInFlight = false }

        let progress = InstallProgress()
        installProgress = progress
        // Blur + spin the affected tiles for the whole operation. The grid
        // is dimmed-but-visible behind the sheet, so the spinner reads as
        // "applying" in real time (DataFontCache renders from bytes, not
        // fontd, so this is safe even during the font-service bounce).
        // They keep their old glyph until finishProgress bumps the
        // generation at the very end.
        model.reloadingFamilyIDs = affected

        let result = await InstallService.install(styles: selected) { update in
            Task { @MainActor in
                progress.apply(update)
            }
        }

        await MainActor.run {
            progress.markFinished()
            // Clear the selection once styles are patched. Without this,
            // the now-patched style IDs linger in selectedStyleIDs — the
            // footer reads "N selected" while the tiles render locked
            // with no checkmark, and Cmd-Return would re-invoke install
            // on already-patched styles.
            model.selectedStyleIDs.removeAll()
        }
        // Intentionally skip `loadFonts()` here: right after a fontd bounce
        // its registration is sparse for several seconds, so a full re-
        // discovery would mark almost every unrelated family as inactive.
        // The on-disk file paths didn't change, so the existing
        // model.families is still valid. The Enshittified tab still
        // re-reads the manifest.
        await loadRestoreFamilies()

        await finishProgress(succeeded: result.errors.isEmpty)
    }

    private func runRestore() async {
        let selected = model.selectedRestoreEntries
        guard !selected.isEmpty else { return }
        // Map restored entries back to the visible families so their tiles
        // show the reload spinner as the original glyph comes back.
        let restoredNames = Set(selected.map(\.familyName))
        let affected = Set(model.families.filter { restoredNames.contains($0.name) }.map(\.id))

        installInFlight = true
        defer { installInFlight = false }

        let progress = InstallProgress()
        progress.action = "Restoring"
        installProgress = progress
        model.reloadingFamilyIDs = affected

        let result = await RestoreService.restore(entries: selected) { update in
            Task { @MainActor in
                progress.apply(update)
            }
        }

        await MainActor.run {
            progress.markFinished()
            model.selectedRestoreIDs.removeAll()
        }
        // See note in runInstall — skip the post-op `loadFonts()` so a
        // mid-bounce fontd doesn't make unrelated families flap to
        // inactive. Manifest-driven restore tab still refreshes.
        await loadRestoreFamilies()

        await finishProgress(succeeded: result.errors.isEmpty)
    }

    /// Restore the patched families selected on the Enshittified tab by
    /// mapping them to their backup entries.
    private func runRestoreFromEnshittified() async {
        let entries = model.selectedEnshittifiedRestoreEntries()
        guard !entries.isEmpty else { return }
        let affected = affectedFamilyIDs(forStyleIDs: Set(model.selectedStyles.map(\.id)))

        installInFlight = true
        defer { installInFlight = false }

        let progress = InstallProgress()
        progress.action = "Restoring"
        installProgress = progress
        model.reloadingFamilyIDs = affected

        let result = await RestoreService.restore(entries: entries) { update in
            Task { @MainActor in
                progress.apply(update)
            }
        }

        await MainActor.run {
            progress.markFinished()
            model.selectedStyleIDs.removeAll()
        }
        await loadRestoreFamilies()

        await finishProgress(succeeded: result.errors.isEmpty)
    }

    /// Shared tail for install/restore. On success: hold the green "Done"
    /// state briefly, dismiss the sheet, let the revealed tiles show their
    /// reload spinner for a beat, THEN bump the font generation so the
    /// preview flips to the new glyph and the spinner clears. The order
    /// matters — bumping the generation is what swaps the rendered bytes,
    /// so deferring it until after the spinner is visible makes the
    /// spinner read as "applying" instead of appearing post-load.
    private func finishProgress(succeeded: Bool) async {
        if succeeded {
            try? await Task.sleep(for: .milliseconds(600))
            await MainActor.run { installProgress = nil }
            try? await Task.sleep(for: .milliseconds(500))
            await MainActor.run {
                model.fontGeneration &+= 1
                model.reloadingFamilyIDs = []
            }
        } else {
            await MainActor.run {
                model.fontGeneration &+= 1
                model.reloadingFamilyIDs = []
            }
        }
    }

    private func affectedFamilyIDs(forStyleIDs styleIDs: Set<String>) -> Set<String> {
        Set(model.families
            .filter { fam in fam.styles.contains { styleIDs.contains($0.id) } }
            .map(\.id))
    }
}

struct ResultAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

// MARK: - Filter bar

/// Font Book-style horizontal pill row: activation filters on the left,
/// optional location filters on the right. Replaces the old toolbar
/// dropdown menu — chips are always visible and reflect current state.
struct FilterBar: View {
    @Environment(AppModel.self) private var model

    /// Every patched system font lives in `~/Library/Fonts/` (the
    /// shadow copy is what we render and what fontd serves), so a
    /// user/system location split has no meaning on the Enshittified
    /// tab — hide those chips there.
    private var showLocationFilter: Bool { model.tab != .enshittified }

    var body: some View {
        @Bindable var model = model

        HStack(spacing: 2) {
            ForEach(AppModel.ActivationFilter.allCases) { f in
                FilterChip(
                    label: f.rawValue,
                    isSelected: model.activationFilter == f
                ) {
                    model.activationFilter = f
                }
            }

            if showLocationFilter {
                Divider()
                    .frame(height: 12)
                    .padding(.horizontal, 6)

                ForEach(AppModel.LocationFilter.allCases) { f in
                    FilterChip(
                        label: shortLabel(for: f),
                        isSelected: model.locationFilter == f
                    ) {
                        model.locationFilter = f
                    }
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func shortLabel(for f: AppModel.LocationFilter) -> String {
        switch f {
        case .all: return "Any Location"
        case .user: return "User"
        case .system: return "System"
        }
    }
}

private struct FilterChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.callout.weight(.semibold))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.primary.opacity(0.16) : Color.clear)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Wraps a toolbar item's content with consistent padding so the system's
/// auto-applied pill background sits at the same scale across items.
/// (On Tahoe the system draws the capsule; we used to draw our own here,
/// which produced a double-border once `ToolbarSpacer` was added.)
struct ToolbarPill<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
    }
}

