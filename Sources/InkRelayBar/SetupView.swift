import AppKit
import InkRelayCore
import SwiftUI

/// First-run setup, the same choices as `inkrelay setup`, without the terminal.
struct SetupView: View {
    @ObservedObject var model: BarModel
    @Environment(\.dismiss) private var dismiss

    private let detector = SetupDetector()
    @State private var tabletIndex = 0
    @State private var useViwoodsCloud = true
    @State private var exportFolder = ""
    @State private var vault = ""
    @State private var appleNotes = true
    @State private var appleCalendar = true
    @State private var appleReminders = true
    @State private var reviewStack = true
    @State private var error: String?

    private var tablet: TabletPreset { TabletPreset.all[tabletIndex] }

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
                Toggle("Apple Notes", isOn: $appleNotes)
                Toggle("Apple Calendar (planner pages and to-dos)", isOn: $appleCalendar)
                Toggle("Apple Reminders (tasks you write)", isOn: $appleReminders)
                Toggle("Review stack (read later)", isOn: $reviewStack)
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Text("Google, Microsoft, Notion and AI transcription are set up in the config; see the README.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onAppear { vault = detector.obsidianVaults().first.map(detector.tilde) ?? "" }
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
        let choices = SetupChoices(
            tablet: tablet,
            useViwoodsCloud: tablet.hasCloudSource && useViwoodsCloud,
            exportFolder: exportFolder.isEmpty ? nil : exportFolder,
            obsidianVault: vault.isEmpty ? nil : vault,
            appleNotesAccount: appleNotes ? .some(nil) : nil,
            appleCalendar: appleCalendar,
            appleReminders: appleReminders,
            reviewStack: reviewStack
        )
        do {
            try ConfigStore.save(try choices.config(), to: model.runner.configURL)
            model.reload()
            dismiss()
        } catch let failure {
            error = failure.localizedDescription
        }
    }
}
