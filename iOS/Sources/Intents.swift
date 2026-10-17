import AppIntents
import Foundation

/// "Get New Ink Notes": the action to chain into Notes. Repeat with each result → Create Note.
struct GetNewInkNotesIntent: AppIntent {
    static var title: LocalizedStringResource = "Get New Ink Notes"
    static var description = IntentDescription(
        "Reads the notes your tablet exported since last time, on this device, and returns one text per note with its title on the first line. Follow it with Repeat with Each and Create Note."
    )

    func perform() async throws -> some IntentResult & ReturnsValue<[String]> {
        let notes = try MobileRelay.shared.newNotes()
        return .result(value: notes.map(\.noteText))
    }
}

/// "Recognize Handwriting": text from any PDF or image, such as one shared from the tablet's app.
struct RecognizeHandwritingIntent: AppIntent {
    static var title: LocalizedStringResource = "Recognize Handwriting"
    static var description = IntentDescription("Reads the handwriting in a PDF or image on this device and returns the text.")

    /// A PDF or an image. (Limiting the picker to those types needs iOS 18.)
    @Parameter(title: "File", description: "A PDF or an image of handwritten pages.")
    var file: IntentFile

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try MobileRelay.shared.recognize(file.data, fileName: file.filename))
    }
}

struct InkRelayShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetNewInkNotesIntent(),
            phrases: ["Get new ink notes in \(.applicationName)", "Check \(.applicationName) for new notes"],
            shortTitle: "New Ink Notes",
            systemImageName: "scribble.variable"
        )
        AppShortcut(
            intent: RecognizeHandwritingIntent(),
            phrases: ["Recognize handwriting with \(.applicationName)"],
            shortTitle: "Recognize Handwriting",
            systemImageName: "doc.text.viewfinder"
        )
    }
}
