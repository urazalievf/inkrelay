import CoreGraphics
import Foundation

/// One recognized line as Vision reports it: text plus a box in normalized page coordinates,
/// origin at the bottom left.
public struct TextLine: Equatable {
    public var text: String
    public var box: CGRect

    public init(text: String, box: CGRect) {
        self.text = text
        self.box = box
    }
}

/// Turns Vision's loose lines back into the shape of the page: paragraphs instead of wrapped lines,
/// list items on their own lines, two columns read one after the other, margin notes set apart.
public enum LayoutBuilder {
    /// Lines wider than this share no column, so they don't hide a gutter (titles, rules).
    static let wideLine: CGFloat = 0.55
    /// The narrowest empty band that counts as a gutter between columns.
    static let minimumGutter: CGFloat = 0.04
    /// A side column this narrow, with fewer lines than the main text, is margin notes.
    static let marginWidth: CGFloat = 0.22

    public static func text(from lines: [TextLine]) -> String {
        let rows = mergeRows(lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })
        guard !rows.isEmpty else { return "" }
        let (main, margin) = split(rows)
        var text = main.map(paragraphs).joined(separator: "\n\n")
        if !margin.isEmpty {
            let notes = margin.map { "> " + $0.text }.joined(separator: "\n")
            text += (text.isEmpty ? "" : "\n\n") + notes
        }
        return text
    }

    // MARK: Rows

    /// Observations on the same baseline become one row, left to right.
    static func mergeRows(_ lines: [TextLine]) -> [TextLine] {
        let ordered = lines.sorted { $0.box.midY > $1.box.midY }
        var rows: [[TextLine]] = []
        for line in ordered {
            if let last = rows.last?.last,
               abs(last.box.midY - line.box.midY) < min(last.box.height, line.box.height) / 2,
               !rows.last!.contains(where: { $0.box.intersects(line.box) }) {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.map { row in
            let sorted = row.sorted { $0.box.minX < $1.box.minX }
            // Fragments far apart on one baseline are separate columns, not one row.
            if sorted.count > 1, zip(sorted, sorted.dropFirst()).contains(where: { $1.box.minX - $0.box.maxX > minimumGutter * 2 }) {
                return sorted
            }
            let box = sorted.dropFirst().reduce(sorted[0].box) { $0.union($1.box) }
            return [TextLine(text: sorted.map(\.text).joined(separator: " "), box: box)]
        }
        .flatMap { $0 }
        .sorted { $0.box.midY > $1.box.midY }
    }

    // MARK: Columns

    /// Groups rows into reading blocks: full-width rows and each column, top to bottom, left column first.
    /// Returns the blocks of the main text and, separately, any margin notes.
    static func split(_ rows: [TextLine]) -> (main: [[TextLine]], margin: [TextLine]) {
        guard let gutter = gutter(in: rows) else { return ([rows], []) }
        let left = rows.filter { $0.box.width <= wideLine && $0.box.maxX <= gutter }
        let right = rows.filter { $0.box.width <= wideLine && $0.box.minX >= gutter }
        let wide = rows.filter { !left.contains($0) && !right.contains($0) }

        func width(_ column: [TextLine]) -> CGFloat {
            (column.map(\.box.maxX).max() ?? 0) - (column.map(\.box.minX).min() ?? 0)
        }
        // A thin column hugging an edge, with fewer lines than the other, is notes in the margin.
        if width(left) < marginWidth, left.count < right.count, (left.map(\.box.minX).min() ?? 1) < 0.2 {
            return (blocks(wide: wide, columns: [right]), left)
        }
        if width(right) < marginWidth, right.count < left.count, (right.map(\.box.maxX).max() ?? 0) > 0.8 {
            return (blocks(wide: wide, columns: [left]), right)
        }
        return (blocks(wide: wide, columns: [left, right]), [])
    }

    /// Wide rows above the columns, then each column, then wide rows below.
    static func blocks(wide: [TextLine], columns: [[TextLine]]) -> [[TextLine]] {
        let columnTop = columns.flatMap { $0 }.map(\.box.maxY).max() ?? 1
        let above = wide.filter { $0.box.midY > columnTop }
        let below = wide.filter { $0.box.midY <= columnTop }
        let mainColumns = columns.filter { !$0.isEmpty }
        if mainColumns.count == 1 {
            return [(above + mainColumns[0] + below).sorted { $0.box.midY > $1.box.midY }]
        }
        return ([above] + mainColumns + [below]).filter { !$0.isEmpty }
    }

    /// The x of an empty vertical band that splits the narrow rows into two groups of at least two, if any.
    static func gutter(in rows: [TextLine]) -> CGFloat? {
        let narrow = rows.filter { $0.box.width <= wideLine }
        guard narrow.count >= 4 else { return nil }
        let spans = narrow.map { ($0.box.minX, $0.box.maxX) }.sorted { $0.0 < $1.0 }
        var reach = spans[0].1
        var best: (x: CGFloat, width: CGFloat)?
        for span in spans.dropFirst() {
            if span.0 - reach >= minimumGutter {
                let x = (reach + span.0) / 2
                let leftCount = narrow.filter { $0.box.maxX <= x }.count
                let rightCount = narrow.count - leftCount
                if leftCount >= 2, rightCount >= 2, best.map({ span.0 - reach > $0.width }) ?? true {
                    best = (x, span.0 - reach)
                }
            }
            reach = max(reach, span.1)
        }
        return best?.x
    }

    // MARK: Paragraphs

    static let bulletMarks: Set<Character> = ["•", "·", "-", "\u{2013}", "\u{2014}", "*", "○", "◦", "▪", "‣", "→"]

    /// Normalizes bullet glyphs to `- `. Checkboxes and numbers are left alone for task detection.
    static func listItem(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return nil }
        if bulletMarks.contains(first) {
            let rest = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : "- " + rest
        }
        if ["☐", "□", "☑", "☒", "✓", "✔"].contains(first) || trimmed.hasPrefix("[ ]") || trimmed.lowercased().hasPrefix("[x]") {
            return trimmed
        }
        if trimmed.range(of: #"^(\d{1,3}|[a-zA-Z])[.)]\s+\S"#, options: .regularExpression) != nil {
            return trimmed
        }
        return nil
    }

    /// Joins wrapped lines into paragraphs and keeps list items and short lines on their own.
    static func paragraphs(_ rows: [TextLine]) -> String {
        guard !rows.isEmpty else { return "" }
        let heights = rows.map(\.box.height).sorted()
        let lineHeight = max(heights[heights.count / 2], 0.001)
        let right = rows.map(\.box.maxX).max() ?? 1
        let left = rows.map(\.box.minX).min() ?? 0
        let width = max(right - left, 0.001)

        var output = ""
        var previous: TextLine?
        for row in rows {
            let item = listItem(row.text)
            let text = item ?? row.text.trimmingCharacters(in: .whitespaces)
            guard let above = previous else {
                output = text
                previous = row
                continue
            }
            let gap = above.box.minY - row.box.maxY
            let aboveText = above.text.trimmingCharacters(in: .whitespaces)
            // A line that stops well short of the right edge wasn't wrapped: the writer broke it.
            let aboveEndsShort = above.box.maxX < right - width * 0.15
            if gap > lineHeight * 0.9 {
                output += "\n\n" + text
            } else if item != nil || listItem(above.text) != nil && row.box.minX <= above.box.minX + width * 0.02 {
                output += "\n" + text
            } else if aboveEndsShort {
                output += "\n" + text
            } else if aboveText.hasSuffix("-"), let first = text.first, first.isLowercase {
                // A word broken across lines.
                output = String(output.dropLast()) + text
            } else {
                output += " " + text
            }
            previous = row
        }
        return output
    }
}
