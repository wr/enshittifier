import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    @State private var installInFlight = false
    @State private var installProgress: InstallProgress?
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
            await loadFonts()
            await loadRestoreFamilies()
        }
        .sheet(item: $installProgress) { progress in
            InstallProgressView(progress: progress)
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
                Button("") { model.tab = .regularFonts }
                    .keyboardShortcut("2", modifiers: .command)
                Button("") { model.tab = .enshittified }
                    .keyboardShortcut("3", modifiers: .command)
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
                Label("Regular Fonts", systemImage: AppModel.Tab.regularFonts.systemImage)
                    .badge(badge(for: .regularFonts))
                    .tag(AppModel.Tab.regularFonts)
                Label {
                    Text("Enshittified Fonts")
                } icon: {
                    PoopGlyph(size: 16, tint: .primary)
                }
                .badge(badge(for: .enshittified))
                .tag(AppModel.Tab.enshittified)
            }
        }
        .listStyle(.sidebar)
    }

    private func badge(for tab: AppModel.Tab) -> Int {
        switch tab {
        case .allFonts: return model.families.count
        case .regularFonts:
            return model.families.filter { !model.isFamilyFullyPatched($0) }.count
        case .enshittified: return model.restoreFamilies.count
        }
    }

    // MARK: - Detail + footer

    @ViewBuilder
    private var detailWithFooter: some View {
        VStack(spacing: 0) {
            if model.showFilterBar {
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

        ToolbarItem(placement: .primaryAction) {
            Button {
                model.showFilterBar.toggle()
            } label: {
                Label("Filters", systemImage: filterIcon)
            }
            .help(model.showFilterBar ? "Hide filters" : "Show filters")
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
        case .allFonts, .regularFonts:
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
                        ContentUnavailableView {
                            Label("Nothing here", systemImage: "checkmark.seal")
                        } description: {
                            Text(model.tab == .regularFonts
                                 ? "Every font has been enshittified. Check Enshittified Fonts to restore them."
                                 : "No fonts found.")
                        }
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
        case .enshittified:
            if model.restoreFamilies.isEmpty {
                ContentUnavailableView {
                    Label {
                        Text("Nothing enshittified yet")
                    } icon: {
                        PoopGlyph(size: 32, tint: .secondary)
                    }
                } description: {
                    Text("Patch some fonts first \u{2014} they\u{2019}ll show up here ready to restore.")
                }
            } else if filteredRestoreFamilies.isEmpty {
                ContentUnavailableView.search(text: model.searchQuery)
            } else {
                RestoreGridView(families: filteredRestoreFamilies)
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
            .disabled(primaryActionDisabled || installInFlight)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var primaryActionIconView: some View {
        if model.tab == .enshittified {
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
        case .allFonts, .regularFonts:
            let total = model.tab == .allFonts ? model.families.count
                : model.families.filter { !model.isFamilyFullyPatched($0) }.count
            let filtered = model.filteredFamilies.count
            return countSummary(filtered: filtered, total: total)
        case .enshittified:
            let total = model.restoreFamilies.count
            let filtered = filteredRestoreFamilies.count
            return "\(countSummary(filtered: filtered, total: total)) currently enshittified"
        }
    }

    private func countSummary(filtered: Int, total: Int) -> String {
        let noun = total == 1 ? "typeface" : "typefaces"
        return filtered == total ? "\(total) \(noun)" : "\(filtered) of \(total) \(noun)"
    }

    private var searchPrompt: String {
        model.tab == .enshittified ? "Search enshittified" : "Search typefaces"
    }

    private var footerSummary: String {
        switch model.tab {
        case .allFonts, .regularFonts:
            let n = model.selectedStyles.count
            if n == 0 { return "Nothing selected" }
            let fams = Set(model.selectedStyles.map(\.familyName)).count
            return "\(fams) famil\(fams == 1 ? "y" : "ies") · \(n) style\(n == 1 ? "" : "s") selected"
        case .enshittified:
            let selected = model.selectedRestoreEntries
            if selected.isEmpty { return "Nothing selected" }
            let fams = Set(selected.map(\.familyName)).count
            return "\(fams) famil\(fams == 1 ? "y" : "ies") · \(selected.count) style\(selected.count == 1 ? "" : "s") selected"
        }
    }

    private var primaryActionLabel: String {
        model.tab == .enshittified ? "Restore Originals" : "Enshittify Selected"
    }

    private var primaryActionIcon: String {
        model.tab == .enshittified ? "arrow.uturn.backward.circle.fill" : "wand.and.stars"
    }

    private var primaryActionEmoji: String {
        model.tab == .enshittified ? "↺" : "💩"
    }

    private var primaryActionTint: Color {
        model.tab == .enshittified ? .orange : .accentColor
    }

    private var primaryActionDisabled: Bool {
        switch model.tab {
        case .allFonts, .regularFonts: return model.selectedStyles.isEmpty
        case .enshittified: return model.selectedRestoreIDs.isEmpty
        }
    }

    private var hasAnyItems: Bool {
        switch model.tab {
        case .allFonts, .regularFonts: return !model.filteredFamilies.isEmpty
        case .enshittified: return !filteredRestoreFamilies.isEmpty
        }
    }

    private var hasAnySelection: Bool {
        switch model.tab {
        case .allFonts, .regularFonts: return !model.selectedStyles.isEmpty
        case .enshittified: return !model.selectedRestoreIDs.isEmpty
        }
    }

    private func selectAll() {
        switch model.tab {
        case .allFonts, .regularFonts:
            // Only select within the current filtered view
            let ids = Set(model.filteredFamilies.flatMap { $0.styles.map(\.id) })
            model.selectedStyleIDs.formUnion(ids)
        case .enshittified:
            let ids = Set(filteredRestoreFamilies.flatMap { $0.entries.map(\.id) })
            model.selectedRestoreIDs.formUnion(ids)
        }
    }

    private func selectNone() {
        switch model.tab {
        case .allFonts, .regularFonts: model.selectedStyleIDs.removeAll()
        case .enshittified: model.selectedRestoreIDs.removeAll()
        }
    }

    private func primaryAction() async {
        switch model.tab {
        case .allFonts, .regularFonts: await runInstall()
        case .enshittified: await runRestore()
        }
    }

    private var filteredRestoreFamilies: [RestoreFamily] {
        let q = model.searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.restoreFamilies }
        return model.restoreFamilies.filter { $0.name.lowercased().contains(q) }
    }

    // MARK: - Loading

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

        installInFlight = true
        defer { installInFlight = false }

        let progress = InstallProgress()
        installProgress = progress

        let result = await InstallService.install(styles: selected) { update in
            Task { @MainActor in
                progress.apply(update)
            }
        }

        await MainActor.run {
            progress.markFinished()
        }
        // Intentionally skip `loadFonts()` here: right after a fontd bounce
        // its registration is sparse for several seconds, so a full re-
        // discovery would mark almost every unrelated family as inactive.
        // The on-disk file paths didn't change, so the existing
        // model.families is still valid. Patched-font previews refresh via
        // the `.process`-scope registration in `refreshFontRegistration`
        // plus the `fontGeneration` bump below — no fontd round-trip
        // needed. The Enshittified tab still re-reads the manifest.
        await loadRestoreFamilies()
        await MainActor.run { model.fontGeneration &+= 1 }

        if !result.errors.isEmpty {
            resultAlert = ResultAlert(
                title: "Some fonts couldn\u{2019}t be patched",
                message: result.errors.joined(separator: "\n")
            )
        }
    }

    private func runRestore() async {
        let selected = model.selectedRestoreEntries
        guard !selected.isEmpty else { return }

        installInFlight = true
        defer { installInFlight = false }

        let progress = InstallProgress()
        progress.action = "Restoring"
        installProgress = progress

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
        await MainActor.run { model.fontGeneration &+= 1 }

        if !result.errors.isEmpty {
            resultAlert = ResultAlert(
                title: "Some fonts couldn\u{2019}t be restored",
                message: result.errors.joined(separator: "\n")
            )
        }
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

