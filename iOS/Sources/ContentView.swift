import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    var body: some View {
        TabView {
            ReviewView()
                .tabItem { Label("Review", systemImage: "rectangle.stack") }
            NotesView()
                .tabItem { Label("Notes", systemImage: "doc.text") }
        }
    }
}

struct NotesView: View {
    private enum Picking { case exports, ledger }

    @State private var folderName = MobileRelay.shared.folderName
    @State private var ledgerName = MobileRelay.shared.ledgerFolderName
    @State private var picking: Picking = .exports
    @State private var choosing = false
    @State private var checking = false
    @State private var notes: [RelayedNote] = []
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        picking = .exports
                        choosing = true
                    } label: {
                        LabeledContent("Export folder") {
                            Text(folderName ?? "Choose…").foregroundStyle(folderName == nil ? Color.accentColor : .secondary)
                        }
                    }
                } footer: {
                    Text("The folder your tablet exports PDFs to, in iCloud Drive, Google Drive, Dropbox or OneDrive.")
                }

                Section {
                    Button {
                        picking = .ledger
                        choosing = true
                    } label: {
                        LabeledContent("Sync with your Mac") {
                            Text(ledgerName ?? "Choose…").foregroundStyle(ledgerName == nil ? Color.accentColor : .secondary)
                        }
                    }
                } footer: {
                    Text("Pick the InkRelay folder in iCloud Drive, the same one the Mac uses. It brings the Mac's review stack here, and a note filed by one isn't filed again by the other.")
                }

                Section {
                    Button {
                        check()
                    } label: {
                        HStack {
                            Label("Check for New Notes", systemImage: "arrow.down.doc")
                            Spacer()
                            if checking { ProgressView() }
                        }
                    }
                    .disabled(folderName == nil || checking)
                    if let message {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                if !notes.isEmpty {
                    Section("New") {
                        ForEach(notes) { note in
                            NavigationLink {
                                NoteView(note: note)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(note.title).font(.headline)
                                    Text(note.text).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                    }
                }

                Section("Shortcuts") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Put new notes in Apple Notes automatically:")
                            .font(.subheadline.weight(.semibold))
                        Text("In Shortcuts, add **Get New Ink Notes**, then **Repeat with Each** and **Create Note** with the Repeat Item. Run it from an automation, such as every morning or when you open Notes.")
                            .font(.subheadline)
                        Text("**Recognize Handwriting** reads any PDF or image you share to it.")
                            .font(.subheadline)
                    }
                    .padding(.vertical, 4)
                    Link(destination: URL(string: "shortcuts://")!) {
                        Label("Open Shortcuts", systemImage: "square.2.layers.3d")
                    }
                }
            }
            .navigationTitle("InkRelay")
            .safeAreaInset(edge: .bottom) {
                Text("Handwriting is read on this device. Nothing is uploaded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
            .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url):
                    do {
                        if picking == .ledger {
                            try MobileRelay.shared.setLedgerFolder(url)
                            ledgerName = MobileRelay.shared.ledgerFolderName
                            message = "The review stack and notes filed by the Mac now come through this folder."
                        } else {
                            try MobileRelay.shared.setFolder(url)
                            folderName = MobileRelay.shared.folderName
                            notes = []
                            message = "Everything already in the folder counts as new the first time."
                        }
                    } catch {
                        message = error.localizedDescription
                    }
                case .failure(let error):
                    message = error.localizedDescription
                }
            }
        }
    }

    private func check() {
        checking = true
        message = nil
        Task.detached(priority: .userInitiated) {
            let result = Result { try MobileRelay.shared.newNotes() }
            await MainActor.run {
                checking = false
                switch result {
                case .success(let found):
                    notes = found + notes.filter { old in !found.contains { $0.id == old.id } }
                    message = found.isEmpty ? "Nothing new since the last check." : "\(found.count) new or changed."
                case .failure(let error):
                    message = error.localizedDescription
                }
            }
        }
    }
}

struct NoteView: View {
    let note: RelayedNote

    var body: some View {
        ScrollView {
            Text(note.text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(note.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: note.noteText)
        }
    }
}
