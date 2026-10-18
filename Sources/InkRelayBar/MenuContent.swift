import InkRelayCore
import SwiftUI

/// The window that drops down from the menu bar icon.
struct MenuContent: View {
    @ObservedObject var model: BarModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.agentRunning {
                agentNotice
            } else if model.needsSetup {
                setupNotice
            } else {
                content
            }
            Divider()
            footer
        }
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(statusColor)
                .frame(width: 20)
                .symbolEffect(.pulse, isActive: model.snapshot.status == .syncing)
            VStack(alignment: .leading, spacing: 1) {
                Text("InkRelay").font(.headline)
                Text(model.statusLine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.syncNow() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Sync now")
                .disabled(model.needsSetup || model.isPaused || model.agentRunning)
            Button { model.togglePause() } label: { Image(systemName: model.isPaused ? "play.fill" : "pause.fill") }
                .buttonStyle(.borderless)
                .help(model.isPaused ? "Resume syncing" : "Pause syncing")
                .disabled(model.needsSetup || model.agentRunning)
        }
        .padding(12)
    }

    private var statusColor: Color {
        switch model.snapshot.status {
        case .attention, .notConfigured: return .orange
        case .paused: return .secondary
        default: return .accentColor
        }
    }

    @ViewBuilder private var content: some View {
        if let update = model.update {
            Row(symbol: "arrow.down.circle", title: "InkRelay \(update.version) is available", detail: "Download") {
                model.open(update.url)
            }
            Divider()
        }
        if model.needsViwoodsSignIn {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sign in to Viwoods Cloud so InkRelay can read your notebooks and planner.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Sign In to Viwoods…") { model.showViwoodsSignIn() }
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
            Divider()
        }
        if !model.snapshot.problems.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.snapshot.problems.prefix(3), id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .lineLimit(2)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
        }
        if let review = model.snapshot.reviewURL {
            Row(symbol: "rectangle.stack", title: model.snapshot.reviewDue == 0 ? "Review stack: all caught up" : "Review stack: \(model.snapshot.reviewDue) waiting") {
                model.open(review)
            }
            Divider()
        }
        if model.snapshot.recent.isEmpty {
            Text("Notes appear here after they sync.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(12)
        } else {
            Text("Recent")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
            VStack(spacing: 0) {
                ForEach(model.snapshot.recent) { note in
                    Row(symbol: "doc.text", title: note.title, detail: note.syncedAt.formatted(.relative(presentation: .named))) {
                        model.open(note.openURL)
                    }
                }
            }
            .padding(.bottom, 4)
        }
    }

    private var setupNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tell InkRelay where your tablet's notes are and where they should go.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button("Set Up InkRelay…") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "setup")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(12)
    }

    private var agentNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The command-line agent is already syncing in the background. Use one or the other, so notes aren't sent twice.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button("Stop the Agent and Sync Here") { model.stopAgentAndStart() }
        }
        .padding(12)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.checkbox)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.entitlement.summary())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    if model.offersLicense {
                        Button("Buy Pro…") { model.buyPro() }
                            .font(.caption)
                        Button("Enter License…") { model.enterLicense() }
                            .font(.caption)
                    }
                }
                if let outlook = model.planOutlook {
                    Text(outlook)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            HStack {
                Button("Settings…") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "setup")
                }
                Menu("More") {
                    Button("Check for Updates…") { model.checkForUpdates() }
                    Button("Enter License…") { model.enterLicense() }
                    Button("Export Diagnostics…") { model.exportDiagnostics() }
                    Divider()
                    Button("Open Config") { model.openConfig() }
                    Button("Open Logs") { model.openLog() }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .buttonStyle(.borderless)
            .font(.callout)
            .padding(12)
        }
    }
}

/// A full-width clickable row that highlights on hover, like a menu item.
private struct Row: View {
    let symbol: String
    let title: String
    var detail: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 16)
                Text(title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
