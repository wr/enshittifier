import SwiftUI
import AppKit

private let cardSample = "I love\nAI"
private let listSample = "I love AI"

/// Maps the modifier keys held at click time to a selection mode, so the
/// grid/list behave like Font Book: plain click selects one, ⌘ toggles,
/// ⇧ extends a range. Reading `NSEvent.modifierFlags` in the tap handler
/// is the pragmatic way to get modifiers — SwiftUI's `onTapGesture`
/// doesn't surface them.
@MainActor
func currentSelectMode() -> SelectMode {
    let flags = NSEvent.modifierFlags
    if flags.contains(.command) { return .toggle }
    if flags.contains(.shift) { return .range }
    return .replace
}

// MARK: - Install grid / list

struct FamilyGridView: View {
    @Environment(AppModel.self) private var model
    let families: [FontFamily]

    @State private var tileFrames: [String: CGRect] = [:]
    @State private var marquee: CGRect?
    @State private var marqueeBase: Set<String> = []

    private static let space = "familygrid"

    var body: some View {
        if model.viewMode == .grid {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: model.tileSize, maximum: model.tileSize), spacing: 16)],
                          alignment: .leading,
                          spacing: 16) {
                    ForEach(families) { family in
                        FamilyTile(family: family)
                            .background(frameReporter(id: family.id))
                    }
                }
                .padding(20)
                // A click on the gaps/padding between tiles lands on this
                // backing layer (tiles sit in front and win their own
                // taps) and clears the selection. Must live on the grid
                // content, not the ScrollView — a background on the
                // ScrollView never receives these taps.
                .background(
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { model.clearSelection() }
                )
            }
            .coordinateSpace(name: Self.space)
            .onPreferenceChange(TileFramesKey.self) { tileFrames = $0 }
            .overlay(alignment: .topLeading) { marqueeRect }
            .gesture(marqueeGesture)
        } else {
            List {
                ForEach(families) { family in
                    FamilyListRow(family: family)
                        .listRowSeparator(.visible)
                        .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
                }
            }
            .listStyle(.inset)
        }
    }

    private func frameReporter(id: String) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: TileFramesKey.self,
                value: [id: geo.frame(in: .named(Self.space))]
            )
        }
    }

    @ViewBuilder
    private var marqueeRect: some View {
        if let m = marquee {
            Rectangle()
                .fill(Color.accentColor.opacity(0.12))
                .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 1))
                .frame(width: m.width, height: m.height)
                .offset(x: m.minX, y: m.minY)
                .allowsHitTesting(false)
        }
    }

    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if marquee == nil {
                    // Capture the starting selection so ⌘/⇧-drag adds to it;
                    // a plain drag replaces.
                    let mods = NSEvent.modifierFlags
                    let additive = mods.contains(.command) || mods.contains(.shift)
                    marqueeBase = additive ? model.selectedStyleIDs : []
                }
                let rect = CGRect(
                    x: min(value.startLocation.x, value.location.x),
                    y: min(value.startLocation.y, value.location.y),
                    width: abs(value.location.x - value.startLocation.x),
                    height: abs(value.location.y - value.startLocation.y)
                )
                marquee = rect
                applyMarquee(rect)
            }
            .onEnded { _ in marquee = nil }
    }

    private func applyMarquee(_ rect: CGRect) {
        var hit = Set<String>()
        for family in families {
            guard let frame = tileFrames[family.id], frame.intersects(rect) else { continue }
            // Skip locked (fully-patched) families on the install tabs;
            // everything on the Enshittified tab is selectable for restore.
            if model.tab.selectsForInstall && model.isFamilyFullyPatched(family) { continue }
            hit.formUnion(family.styles.map(\.id))
        }
        model.selectedStyleIDs = marqueeBase.union(hit)
    }
}

/// Collects each tile's frame (keyed by family id) in the grid coordinate
/// space so the marquee can hit-test against them.
private struct TileFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct FamilyTile: View {
    @Environment(AppModel.self) private var model
    let family: FontFamily

    private var selection: SelectionState { model.selectionState(for: family) }
    private var isSelected: Bool { selection != .off && !isLocked }
    private var isFamilyInactive: Bool {
        !family.styles.isEmpty && family.styles.allSatisfy { !$0.isActivated }
    }
    private var isPatched: Bool { model.isFamilyPartiallyPatched(family) }
    /// Lock the family when there's nothing left to do — either the tab
    /// is read-only or every style is already patched. Partially-patched
    /// families stay tappable on the install tabs so the user can finish
    /// the remaining styles; `InstallService.installOne` is idempotent
    /// on its backup step (skips when a backup already exists) so a
    /// mixed selection re-applies safely.
    private var isLocked: Bool { model.tab.selectsForInstall && model.isFamilyFullyPatched(family) }

    var body: some View {
        VStack(spacing: 8) {
            FontSampleTile(
                familyName: family.name,
                previewURL: family.previewURL,
                sample: cardSample,
                styleCount: family.styleCount,
                location: locationKind,
                isSelected: isSelected,
                tileHeight: model.tileSize * 0.78,
                isActivated: !isFamilyInactive,
                isPatched: isPatched,
                isReloading: model.reloadingFamilyIDs.contains(family.id)
            )
            .id(model.fontGeneration)
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isLocked else { return }
                model.clickFamily(family, in: model.filteredFamilies, mode: currentSelectMode())
            }
            .help(family.name)
            .contextMenu { familyContextMenu(for: family) }

            Text(family.name)
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
                .opacity(isFamilyInactive ? 0.45 : 1.0)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
    }

    private var locationKind: FamilyTileLocation {
        let user = family.styles.contains { $0.location == .user }
        let system = family.styles.contains { $0.location == .system }
        switch (user, system) {
        case (true, true): return .mixed
        case (true, false): return .user
        case (false, true): return .system
        case (false, false): return .user
        }
    }
}

private struct FamilyListRow: View {
    @Environment(AppModel.self) private var model
    let family: FontFamily

    private var selection: SelectionState { model.selectionState(for: family) }
    private var isSelected: Bool { selection != .off && !isLocked }
    private var isFamilyInactive: Bool {
        !family.styles.isEmpty && family.styles.allSatisfy { !$0.isActivated }
    }
    private var isPatched: Bool { model.isFamilyPartiallyPatched(family) }
    private var isLocked: Bool { model.tab.selectsForInstall && model.isFamilyFullyPatched(family) }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            if isLocked {
                // Lock affordance for already-patched families on the
                // install tabs (right-click to restore).
                Image(systemName: "lock.fill")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18, height: 18)
                    .padding(.top, 6)
                    .help("Already enshittified. Right-click to restore.")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(listSample)
                    .font(resolvedListFont)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(.primary)
                    .opacity(isFamilyInactive ? 0.35 : 1.0)
                    .id(model.fontGeneration)

                HStack(spacing: 6) {
                    Text(family.name)
                        .font(.caption.weight(.medium))
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("\(family.styleCount) style\(family.styleCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LocationBadge(location: locationKind, compact: true)
                    if isPatched {
                        PatchedBadge(compact: true)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isLocked else { return }
            model.clickFamily(family, in: model.filteredFamilies, mode: currentSelectMode())
        }
        .contextMenu { familyContextMenu(for: family) }
    }

    private var previewFontSize: CGFloat {
        // Slider 128…260 → preview 18…44pt
        let t = (model.tileSize - 128) / (260 - 128)
        return 18 + t * 26
    }

    private var resolvedListFont: Font {
        if let url = family.previewURL,
           let f = DataFontCache.font(at: url, size: previewFontSize) {
            return f
        }
        return .custom(family.name, size: previewFontSize, relativeTo: .title2)
    }

    private var locationKind: FamilyTileLocation {
        let user = family.styles.contains { $0.location == .user }
        let system = family.styles.contains { $0.location == .system }
        switch (user, system) {
        case (true, true): return .mixed
        case (true, false): return .user
        case (false, true): return .system
        case (false, false): return .user
        }
    }
}

// MARK: - Restore grid / list

struct RestoreGridView: View {
    @Environment(AppModel.self) private var model
    let families: [RestoreFamily]

    @State private var tileFrames: [String: CGRect] = [:]
    @State private var marquee: CGRect?
    @State private var marqueeBase: Set<String> = []

    private static let space = "restoregrid"

    var body: some View {
        if model.viewMode == .grid {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: model.tileSize, maximum: model.tileSize), spacing: 16)],
                          alignment: .leading,
                          spacing: 16) {
                    ForEach(families) { family in
                        RestoreFamilyTile(family: family)
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: TileFramesKey.self,
                                        value: [family.id: geo.frame(in: .named(Self.space))]
                                    )
                                }
                            )
                    }
                }
                .padding(20)
                .background(
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { model.clearSelection() }
                )
            }
            .coordinateSpace(name: Self.space)
            .onPreferenceChange(TileFramesKey.self) { tileFrames = $0 }
            .overlay(alignment: .topLeading) { marqueeRect }
            .gesture(marqueeGesture)
        } else {
            List {
                ForEach(families) { family in
                    RestoreFamilyListRow(family: family)
                        .listRowSeparator(.visible)
                        .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
                }
            }
            .listStyle(.inset)
        }
    }

    @ViewBuilder
    private var marqueeRect: some View {
        if let m = marquee {
            Rectangle()
                .fill(Color.accentColor.opacity(0.12))
                .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 1))
                .frame(width: m.width, height: m.height)
                .offset(x: m.minX, y: m.minY)
                .allowsHitTesting(false)
        }
    }

    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if marquee == nil {
                    let mods = NSEvent.modifierFlags
                    let additive = mods.contains(.command) || mods.contains(.shift)
                    marqueeBase = additive ? model.selectedRestoreIDs : []
                }
                let rect = CGRect(
                    x: min(value.startLocation.x, value.location.x),
                    y: min(value.startLocation.y, value.location.y),
                    width: abs(value.location.x - value.startLocation.x),
                    height: abs(value.location.y - value.startLocation.y)
                )
                marquee = rect
                var hit = Set<String>()
                for family in families where (tileFrames[family.id]?.intersects(rect) ?? false) {
                    hit.formUnion(family.entries.map(\.id))
                }
                model.selectedRestoreIDs = marqueeBase.union(hit)
            }
            .onEnded { _ in marquee = nil }
    }
}

private struct RestoreFamilyTile: View {
    @Environment(AppModel.self) private var model
    let family: RestoreFamily

    private var selection: SelectionState { model.restoreSelectionState(for: family) }
    private var isSelected: Bool { selection != .off }

    var body: some View {
        VStack(spacing: 8) {
            FontSampleTile(
                familyName: family.name,
                previewURL: family.previewURL,
                sample: cardSample,
                styleCount: family.entryCount,
                location: locationKind,
                isSelected: isSelected,
                tileHeight: model.tileSize * 0.78
            )
            .id(model.fontGeneration)
            .contentShape(Rectangle())
            .onTapGesture {
                model.clickRestoreFamily(family, in: model.filteredRestoreFamilies, mode: currentSelectMode())
            }
            .help(family.name)
            .contextMenu { restoreContextMenu(for: family) }

            Text(family.name)
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
        }
    }

    private var locationKind: FamilyTileLocation {
        let user = family.entries.contains { $0.location == .user }
        let system = family.entries.contains { $0.location == .system }
        switch (user, system) {
        case (true, true): return .mixed
        case (true, false): return .user
        case (false, true): return .system
        case (false, false): return .user
        }
    }
}

private struct RestoreFamilyListRow: View {
    @Environment(AppModel.self) private var model
    let family: RestoreFamily

    private var selection: SelectionState { model.restoreSelectionState(for: family) }
    private var isSelected: Bool { selection != .off }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(listSample)
                    .font(resolvedListFont)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(.primary)
                    .id(model.fontGeneration)

                HStack(spacing: 6) {
                    Text(family.name)
                        .font(.caption.weight(.medium))
                    Text("·")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("\(family.entryCount) backed-up style\(family.entryCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    LocationBadge(location: locationKind, compact: true)
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            model.clickRestoreFamily(family, in: model.filteredRestoreFamilies, mode: currentSelectMode())
        }
        .contextMenu { restoreContextMenu(for: family) }
    }

    private var previewFontSize: CGFloat {
        let t = (model.tileSize - 128) / (260 - 128)
        return 18 + t * 26
    }

    private var resolvedListFont: Font {
        if let url = family.previewURL,
           let f = DataFontCache.font(at: url, size: previewFontSize) {
            return f
        }
        return .custom(family.name, size: previewFontSize, relativeTo: .title2)
    }

    private var locationKind: FamilyTileLocation {
        let user = family.entries.contains { $0.location == .user }
        let system = family.entries.contains { $0.location == .system }
        switch (user, system) {
        case (true, true): return .mixed
        case (true, false): return .user
        case (false, true): return .system
        case (false, false): return .user
        }
    }
}

// MARK: - Context menus

@MainActor
@ViewBuilder
private func familyContextMenu(for family: FontFamily) -> some View {
    EnvironmentAwareInstallMenu(family: family)
}

@MainActor
@ViewBuilder
private func restoreContextMenu(for family: RestoreFamily) -> some View {
    EnvironmentAwareRestoreMenu(family: family)
}

private struct EnvironmentAwareInstallMenu: View {
    @Environment(AppModel.self) private var model
    let family: FontFamily

    private var isLocked: Bool {
        model.tab.selectsForInstall && model.isFamilyFullyPatched(family)
    }

    var body: some View {
        if !isLocked {
            Button {
                for s in family.styles { model.selectedStyleIDs.insert(s.id) }
            } label: {
                Label("Select Family", systemImage: "checkmark.circle")
            }
            Button {
                for s in family.styles { model.selectedStyleIDs.remove(s.id) }
            } label: {
                Label("Deselect Family", systemImage: "circle")
            }
            Divider()
        }
        if model.isFamilyPartiallyPatched(family) {
            Button {
                jumpToRestore(family: family, model: model)
            } label: {
                Label("Restore Original\u{2026}", systemImage: "arrow.uturn.backward")
            }
            Divider()
        }
        Button {
            showInFontBook(family.styles.first?.url)
        } label: {
            Label("Show in Font Book", systemImage: "textformat")
        }
        .disabled(family.styles.first == nil)
        Button {
            revealInFinder(family.styles.first?.url)
        } label: {
            Label("Show in Finder", systemImage: "magnifyingglass")
        }
        .disabled(family.styles.first == nil)
    }
}

@MainActor
private func jumpToRestore(family: FontFamily, model: AppModel) {
    model.tab = .restoreOriginals
    if let restore = model.restoreFamilies.first(where: { $0.name == family.name }) {
        model.selectedRestoreIDs.formUnion(restore.entries.map(\.id))
    }
}

private struct EnvironmentAwareRestoreMenu: View {
    @Environment(AppModel.self) private var model
    let family: RestoreFamily

    var body: some View {
        Button {
            for e in family.entries { model.selectedRestoreIDs.insert(e.id) }
        } label: {
            Label("Select Family", systemImage: "checkmark.circle")
        }
        Button {
            for e in family.entries { model.selectedRestoreIDs.remove(e.id) }
        } label: {
            Label("Deselect Family", systemImage: "circle")
        }
        Divider()
        Button {
            showInFontBook(family.entries.first?.livePath)
        } label: {
            Label("Show in Font Book", systemImage: "textformat")
        }
        .disabled(family.entries.first == nil)
        Button {
            revealInFinder(family.entries.first?.livePath)
        } label: {
            Label("Reveal Patched File in Finder", systemImage: "magnifyingglass")
        }
        Button {
            revealInFinder(family.entries.first?.backupPath)
        } label: {
            Label("Reveal Backup in Finder", systemImage: "tray.and.arrow.up")
        }
    }
}

@MainActor
private func revealInFinder(_ url: URL?) {
    guard let url else { return }
    NSWorkspace.shared.activateFileViewerSelecting([url])
}

@MainActor
private func showInFontBook(_ url: URL?) {
    guard let url else { return }
    let fontBook = URL(fileURLWithPath: "/System/Applications/Font Book.app")
    let config = NSWorkspace.OpenConfiguration()
    NSWorkspace.shared.open([url], withApplicationAt: fontBook, configuration: config) { _, _ in }
}

// MARK: - Reusable pieces

private struct LocationBadge: View {
    let location: FamilyTileLocation
    var compact: Bool = false
    @State private var showExplainer = false

    // Graphite chip palette — deliberately neutral so the "System font"
    // tag doesn't read as a warning and never competes with the orange
    // Enshittify action / Patched badge sitting next to it.
    private var chipBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            if appearance.isDark {
                return NSColor(srgbRed: 0.55, green: 0.56, blue: 0.58, alpha: 0.28)
            }
            return NSColor(srgbRed: 0.90, green: 0.90, blue: 0.92, alpha: 1.0)
        })
    }

    private var chipForeground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            if appearance.isDark {
                return NSColor(srgbRed: 0.82, green: 0.83, blue: 0.85, alpha: 1.0)
            }
            return NSColor(srgbRed: 0.30, green: 0.31, blue: 0.34, alpha: 1.0)
        })
    }

    var body: some View {
        if location != .user {
            Button {
                showExplainer.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "gear")
                        .font(.system(size: compact ? 9 : 10, weight: .semibold))
                    Text(location == .system ? "System font" : "Mixed")
                        .font(.system(size: compact ? 9 : 10, weight: .semibold))
                }
                .foregroundStyle(chipForeground)
                .padding(.horizontal, compact ? 6 : 8)
                .padding(.vertical, compact ? 2 : 3)
                .background(Capsule().fill(chipBackground))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                if hovering {
                    NSCursor.helpCursorCompat.push()
                } else {
                    NSCursor.pop()
                }
            }
            .help("How system fonts get patched")
            .popover(isPresented: $showExplainer, arrowEdge: .top) {
                SystemFontExplainer(location: location)
            }
        }
    }
}

/// "Patched" pill — pairs the in-app PoopGlyph with the word so the
/// badge reads at a glance on dense grids. Orange palette to match the
/// Enshittify action; the neutral graphite "System font" chip sits
/// beside it on shadowed system fonts without clashing.
struct PatchedBadge: View {
    var compact: Bool = false

    private var chipBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            if appearance.isDark {
                return NSColor(srgbRed: 0.90, green: 0.50, blue: 0.10, alpha: 0.30)
            }
            return NSColor(srgbRed: 1.00, green: 0.88, blue: 0.74, alpha: 1.0)
        })
    }

    private var chipForeground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            if appearance.isDark {
                return NSColor(srgbRed: 1.00, green: 0.78, blue: 0.50, alpha: 1.0)
            }
            return NSColor(srgbRed: 0.60, green: 0.30, blue: 0.00, alpha: 1.0)
        })
    }

    var body: some View {
        HStack(spacing: 4) {
            PoopGlyph(size: compact ? 10 : 12, tint: chipForeground)
            Text("Patched")
                .font(.system(size: compact ? 9 : 10, weight: .semibold))
                .foregroundStyle(chipForeground)
        }
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 2 : 3)
        .background(Capsule().fill(chipBackground))
        .help("This family has been enshittified")
    }
}

private extension NSCursor {
    /// AppKit ships a `?` help cursor but exposes it only via a private
    /// selector. Falls back to the pointing-hand cursor if unavailable.
    static var helpCursorCompat: NSCursor {
        let sel = NSSelectorFromString("_helpCursor")
        if NSCursor.responds(to: sel),
           let unmanaged = NSCursor.perform(sel),
           let cursor = unmanaged.takeUnretainedValue() as? NSCursor {
            return cursor
        }
        return .pointingHand
    }
}

private extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.darkAqua, .vibrantDark,
                         .accessibilityHighContrastDarkAqua,
                         .accessibilityHighContrastVibrantDark]) != nil
    }
}

private struct SystemFontExplainer: View {
    let location: FamilyTileLocation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.orange)
                Text(location == .system ? "System font override" : "Mixed user + system")
                    .font(.headline)
            }
            Text("macOS loads fonts from ~/Library/Fonts before /System/Library/Fonts. Enshittifying a system font writes a patched copy into your user fonts folder, which then overrides the system version for every app.")
                .font(.callout)
                .foregroundStyle(.primary)
            Text("The original file in /System/Library/Fonts is never touched. Restoring just removes the user-fonts copy and the system one takes over again.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
    }
}

// MARK: - Shared tile body

enum FamilyTileLocation {
    case user, system, mixed
}

struct FontSampleTile: View {
    let familyName: String
    /// Specific file URL to render bytes from. When provided, we build the
    /// SwiftUI Font directly from the file's bytes via `DataFontCache`,
    /// bypassing CoreText's family-name resolution cache so in-place
    /// patches are visible without an app relaunch.
    var previewURL: URL? = nil
    let sample: String
    let styleCount: Int
    let location: FamilyTileLocation
    let isSelected: Bool
    var tileHeight: CGFloat = 120
    var isActivated: Bool = true
    var isPatched: Bool = false
    /// True while this family was just patched and its preview is being
    /// re-resolved from the new bytes — show a spinner over the sample.
    var isReloading: Bool = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected
                      ? AnyShapeStyle(Color.accentColor.opacity(0.16))
                      : AnyShapeStyle(Color(nsColor: .controlBackgroundColor)))

            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                    lineWidth: isSelected ? 2 : 0.5
                )

            // Centered sample — supports multi-line via \n. While
            // reloading we deliberately render the placeholder in the
            // SYSTEM font, never `resolvedSampleFont`: the latter can fall
            // back to `.custom(family)`, which routes through CoreText/
            // fontd — and these tiles re-render exactly while the font
            // daemon is bounced during a patch/restore, so resolving a
            // family name there can block the main thread (the occasional
            // post-op hang). The blurred system-font shape reads fine
            // behind the spinner.
            Text(sample)
                .font(isReloading ? .system(size: sampleFontSize) : resolvedSampleFont)
                .lineSpacing(2)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .minimumScaleFactor(0.35)
                .foregroundStyle(.primary)
                .opacity(isReloading ? 0.12 : (isActivated ? 1.0 : 0.35))
                .padding(.horizontal, 14)
                .padding(.bottom, 8)

            if isReloading {
                ProgressView()
                    .controlSize(.large)
                    .scaleEffect(1.8)
                    .transition(.opacity)
            }

            // Bottom-left style count + location/patched pills
            VStack {
                Spacer()
                HStack(spacing: 6) {
                    Text(styleCountText)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if isPatched {
                        PatchedBadge(compact: true)
                    }
                    LocationBadge(location: location, compact: true)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
        .frame(height: tileHeight)
    }

    /// Scale sample text proportionally with tile height. At small (~100pt)
    /// → ~22pt; at large (~200pt) → ~44pt. No upper cap so the resizer
    /// actually does what its name says.
    private var sampleFontSize: CGFloat {
        max(14, tileHeight * 0.22)
    }

    private var resolvedSampleFont: Font {
        if let url = previewURL,
           let f = DataFontCache.font(at: url, size: sampleFontSize) {
            return f
        }
        return .custom(familyName, size: sampleFontSize, relativeTo: .title)
    }

    private var styleCountText: String {
        styleCount == 1 ? "1 style" : "\(styleCount) styles"
    }
}
