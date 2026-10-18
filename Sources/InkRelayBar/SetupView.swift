import AppKit
import InkRelayCore
import SwiftUI

/// Setup and Settings in one window: the same choices as `inkrelay setup`, shown again prefilled from the config,
/// and saved without touching the sections it doesn't show.
struct SetupView: View {
    @ObservedObject var model: BarModel
    @Environment(\.dismiss) private var dismiss

    private let detector = SetupDetector()
    @State private var tabletIndex = 0
    @State private var useViwoodsCloud = true
    @State private var exportFolder = ""
    @State private var vault = ""
    @State private var dailyNotes = false
    @State private var weeklyDigest = false
    @State private var appleNotes = true
    @State private var appleCalendar = true
    @State private var appleReminders = true
    @State private var reviewStack = true
    @State private var shareWithPhone = false
    @State private var notifyProblems = true
    @State private var notifyNewNotes = false
    @State private var remind = false
    @State private var reminderTime = Calendar.current.date(from: DateComponents(hour: 9, minute: 0)) ?? Date()
    @State private var error: String?
    @State private var loadError: String?
    @State private var loaded = false

    private var tablet: TabletPreset { TabletPreset.all[tabletIndex] }
    private var hasConfig: Bool { model.config != nil }

    var body: some View {
        Form {
            Section("Tablet") {
                Picker("Tablet", selection: $tabletIndex) {
                    ForEach(TabletPreset.all.indices, id: \.self) { Text(TabletPreset.all[$0].name).tag($0) }
                }
                if tablet.hasCloudSource {
                    Toggle("Read straight from Viwoods Cloud", isOn: $useViwoodsCloud)
                }
                Text(tablet.exportHint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Export folder") {
                folderPicker(selection: $exportFolder, suggestions: detector.cloudFolders().map { detector.tilde($0.url) }, none: tablet.hasCloudSource && useViwoodsCloud ? "None" : nil)
            }
            Section("Where notes go") {
                folderPicker(selection: $vault, suggestions: detector.obsidianVaults().map(detector.tilde), none: "No Obsidian", label: "Obsidian vault")
                if !vault.isEmpty {
                    Toggle("Add to the vault's daily notes", isOn: $dailyNotes)
                    Toggle("Keep a weekly digest (Ink/Weekly)", isOn: $weeklyDigest)
                }
                Toggle("Apple Notes", isOn: $appleNotes)
                Toggle("Apple Calendar (planner pages and to-dos)", isOn: $appleCalendar)
                Toggle("Apple Reminders (tasks you write)", isOn: $appleReminders)
                Toggle("Review stack (read later)", isOn: $reviewStack)
                if appleNotes || reviewStack, SharedLedger.iCloudDriveFolder != nil {
                    Toggle("Share with InkRelay on iPhone and iPad (iCloud Drive)", isOn: $shareWithPhone)
                }
            }
            Section("Notifications") {
                Toggle("Tell me when something needs me", isOn: $notifyProblems)
                Toggle("Tell me when new notes sync", isOn: $notifyNewNotes)
                if reviewStack {
                    Toggle("Daily review reminder", isOn: $remind)
                    if remind {
                        DatePicker("At", selection: $reminderTime, displayedComponents: .hourAndMinute)
                    }
                }
            }
            if let loadError {
                Text("Your config couldn't be read: \(loadError) Saving replaces it; the old file is kept as config.json.bak.")
                    .foregroundStyle(.orange).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Text("Google, Microsoft, Notion, AI transcription and send targets are set in the config file and kept as they are.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let config = model.config else {
            if FileManager.default.fileExists(atPath: model.runner.configURL.path) {
                do { _ = try ConfigStore.load(from: model.runner.configURL) } catch { loadError = error.localizedDescription }
            }
            vault = detector.obsidianVaults().first.map(detector.tilde) ?? ""
            // A vault with Daily Notes set up gets the block offered; nothing is written until Save.
            dailyNotes = !vault.isEmpty && DailyNotesSettings.isEnabled(vault: URL(fileURLWithPath: (vault as NSString).expandingTildeInPath, isDirectory: true))
            return
        }
        let choices = SetupChoices(from: config)
        tabletIndex = TabletPreset.all.firstIndex { $0.name == choices.tablet.name } ?? 0
        useViwoodsCloud = choices.useViwoodsCloud
        exportFolder = choices.exportFolder ?? ""
        vault = choices.obsidianVault ?? ""
        dailyNotes = choices.dailyNotes
        weeklyDigest = choices.weeklyDigest
        appleNotes = choices.appleNotesAccount != nil
        appleCalendar = choices.appleCalendar
        appleReminders = choices.appleReminders
        reviewStack = choices.reviewStack
        shareWithPhone = choices.shareWithPhone
        notifyProblems = choices.notifyProblems
        notifyNewNotes = choices.notifyNewNotes
        if let time = config.notifications.reminderTime {
            remind = true
            reminderTime = Calendar.current.date(from: DateComponents(hour: time.hour, minute: time.minute)) ?? reminderTime
        }
    }

    private func folderPicker(selection: Binding<String>, suggestions: [String], none: String?, label: String = "Folder") -> some View {
        HStack {
            Picker(label, selection: selection) {
                if let none { Text(none).tag("") }
                ForEach(suggestions, id: \.self) { Text($0).tag($0) }
                if !selection.wrappedValue.isEmpty, !suggestions.contains(selection.wrappedValue) {
                    Text(selection.wrappedValue).tag(selection.wrappedValue)
                }
            }
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                if panel.runModal() == .OK, let url = panel.url { selection.wrappedValue = detector.tilde(url) }
            }
        }
    }

    private func save() {
        let existing = model.config
        var choices = SetupChoices(
            tablet: tablet,
            useViwoodsCloud: tablet.hasCloudSource && useViwoodsCloud,
            exportFolder: exportFolder.isEmpty ? nil : exportFolder,
            obsidianVault: vault.isEmpty ? nil : vault,
            appleNotesAccount: appleNotes ? .some(existing?.destinations.compactMap { if case .appleNotes(let n) = $0 { return n.account } else { return nil } }.first ?? nil) : nil,
            appleCalendar: appleCalendar,
            appleReminders: appleReminders,
            reviewStack: reviewStack,
            shareWithPhone: shareWithPhone
        )
        choices.kindleMail = existing?.kindleMail != nil
        choices.dailyNotes = !vault.isEmpty && dailyNotes
        choices.weeklyDigest = !vault.isEmpty && weeklyDigest
        choices.notifyProblems = notifyProblems
        choices.notifyNewNotes = notifyNewNotes
        if remind, reviewStack {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: reminderTime)
            choices.reviewReminder = String(format: "%02d:%02d", parts.hour ?? 9, parts.minute ?? 0)
        }
        do {
            try ConfigStore.replace(try choices.config(merging: existing), at: model.runner.configURL)
            model.reload()
            dismiss()
        } catch let failure {
            error = failure.localizedDescription
        }
    }
}
