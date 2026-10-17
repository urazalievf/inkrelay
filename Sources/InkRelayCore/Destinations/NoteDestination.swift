import Foundation

/// A notes app InkRelay writes into.
public protocol NoteDestination {
    var id: String { get }

    /// Creates the note, or updates it in place when `previous` says it was sent before.
    /// Returns the destination's handle for the note, stored for the next update.
    func upsert(_ note: InkNote, previous: DestinationRecord?) throws -> String
}

public enum DestinationFactory {
    public static func make(_ configs: [DestinationConfig], scriptRunner: AppleScriptRunner = OSAScriptRunner()) -> [NoteDestination] {
        configs.map { config in
            switch config {
            case .obsidian(let obsidian):
                return ObsidianDestination(config: obsidian)
            case .appleNotes(let notes):
                return AppleNotesDestination(config: notes, runner: scriptRunner)
            case .appleCalendar(let calendar):
                return AppleCalendarDestination(config: calendar, runner: scriptRunner)
            }
        }
    }

    /// The destinations that also take planner to-dos.
    public static func plans(in destinations: [NoteDestination]) -> [PlanDestination] {
        destinations.compactMap { $0 as? PlanDestination }
    }
}

enum NoteFormatting {
    static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func hasText(_ note: InkNote) -> Bool {
        note.pages.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
