import UIKit

// The figures a process row shows after its name, in the order they appear.
enum ProcessColumn: CaseIterable {
    case pid
    case cpu
    case memory
    case threads

    // When a row is too narrow for all of them, the least telling go first.
    static let byPriority: [ProcessColumn] = [.cpu, .memory, .pid, .threads]

    // Headings are short, since a column is at least as wide as its
    // heading; VoiceOver reads the sort order's longer name instead.
    var title: String {
        switch self {
        case .pid: String(localized: "PID")
        case .cpu: String(localized: "CPU")
        case .memory: String(localized: "Memory")
        case .threads: String(localized: "Threads")
        }
    }

    var sortOrder: ProcessSortOrder {
        switch self {
        case .pid: .pid
        case .cpu: .cpu
        case .memory: .memory
        case .threads: .threads
        }
    }
}

// Fonts and column widths for one text size, shared by every row and the
// heading above them. A column is as wide as the widest figure it can hold,
// measured once here — never from the row being drawn — so the figures line
// up from row to row and under their headings. At the accessibility sizes a
// row has no room for columns, and stacks its figures under the name.
final class ProcessListMetrics {
    let isStacked: Bool
    let nameFont: UIFont
    let valueFont: UIFont
    let titleFont: UIFont
    let summaryFont: UIFont
    let iconSize: CGFloat
    let iconSpacing: CGFloat
    let columnSpacing: CGFloat
    let rowHeight: CGFloat
    let titleRowHeight: CGFloat
    private let minimumNameWidth: CGFloat
    private let widths: [ProcessColumn: CGFloat]

    private static var cache: [UIContentSizeCategory: ProcessListMetrics] = [:]

    static func metrics(for category: UIContentSizeCategory) -> ProcessListMetrics {
        // A view outside a window reports no text size; the app's stands in.
        let category = category == .unspecified
            ? UIApplication.shared.preferredContentSizeCategory
            : category
        if let cached = cache[category] { return cached }
        let metrics = ProcessListMetrics(category: category)
        cache[category] = metrics
        return metrics
    }

    private init(category: UIContentSizeCategory) {
        let traits = UITraitCollection(preferredContentSizeCategory: category)
        isStacked = category.isAccessibilityCategory
        nameFont = .preferredFont(forTextStyle: isStacked ? .body : .subheadline, compatibleWith: traits)
        valueFont = .inspector(.footnote, design: .monospacedDigit, compatibleWith: traits)
        titleFont = .inspector(.caption1, weight: .semibold, compatibleWith: traits)
        summaryFont = .preferredFont(forTextStyle: .footnote, compatibleWith: traits)
        iconSize = isStacked ? 36 : 28
        iconSpacing = 10
        columnSpacing = (valueFont.pointSize * 0.75).rounded()
        minimumNameWidth = (nameFont.pointSize * 5.5).rounded()
        titleRowHeight = ceil(titleFont.lineHeight) + 12

        let valueLine = ceil(valueFont.lineHeight)
        let nameLine = ceil(nameFont.lineHeight)
        rowHeight = isStacked
            // The name, then CPU and memory, then PID and threads.
            ? max(iconSize, nameLine + 2 * (Self.lineSpacing + valueLine)) + 2 * Self.stackedPadding
            : max(iconSize, nameLine, valueLine) + 2 * Self.rowPadding

        // The widest figure each column can hold. Digits are all one width in
        // this font, so eights stand for any number of that length.
        let samples: [ProcessColumn: [String]] = [
            .pid: ["88888"],
            .cpu: [InspectorFormat.percent(8.888)],
            .memory: [
                InspectorFormat.memoryColumn((1000 << 20) - (100 << 10)),
                InspectorFormat.memoryColumn((100 << 30) - (10 << 20)),
                InspectorFormat.memoryColumn(999 << 10),
            ],
            .threads: ["888"],
        ]
        // A heading also has to fit the arrow it carries while sorted.
        let arrow = UIImage(systemName: "chevron.down", withConfiguration: Self.arrowConfiguration)
        let arrowWidth = ceil(arrow?.size.width ?? 8)
        var widths: [ProcessColumn: CGFloat] = [:]
        for column in ProcessColumn.allCases {
            var width = Self.width(of: column.title, in: titleFont) + arrowWidth
            for sample in samples[column, default: []] {
                width = max(width, Self.width(of: sample, in: valueFont))
            }
            widths[column] = width
        }
        self.widths = widths
    }

    // The sorted heading's arrow, the size a detail table's is.
    static let arrowConfiguration = UIImage.SymbolConfiguration(pointSize: 8, weight: .bold)
    static let rowPadding: CGFloat = 8
    static let stackedPadding: CGFloat = 10
    static let lineSpacing: CGFloat = 2

    func width(of column: ProcessColumn) -> CGFloat {
        widths[column, default: 0]
    }

    // The columns that fit beside a name in a row this wide, in display order.
    // CPU always shows; each further column must leave the name its minimum.
    func columns(fittingWidth contentWidth: CGFloat) -> [ProcessColumn] {
        var remaining = contentWidth - iconSize - iconSpacing
        var shown: Set<ProcessColumn> = []
        for column in ProcessColumn.byPriority {
            let needed = width(of: column) + columnSpacing
            guard shown.isEmpty || remaining - needed >= minimumNameWidth else { break }
            remaining -= needed
            shown.insert(column)
        }
        return ProcessColumn.allCases.filter(shown.contains)
    }

    // Where each part of a columnar row goes, across `content` (a row's
    // content area, between its margins). Every rect spans the full height of
    // `content`; callers place text within it. Right-to-left mirrors the lot.
    func columnLayout(in content: CGRect, isRightToLeft: Bool) -> ProcessListColumnLayout {
        func span(from minX: CGFloat, to maxX: CGFloat) -> CGRect {
            CGRect(x: minX, y: content.minY, width: max(0, maxX - minX), height: content.height)
        }
        var layout = ProcessListColumnLayout()
        // Figures fill in from the trailing edge; the name takes what's left.
        var trailing = content.maxX
        for column in columns(fittingWidth: content.width).reversed() {
            let leading = trailing - width(of: column)
            layout.columns.insert((column, span(from: leading, to: trailing)), at: 0)
            trailing = leading - columnSpacing
        }
        layout.icon = span(from: content.minX, to: content.minX + iconSize)
        layout.name = span(from: layout.icon.maxX + iconSpacing, to: trailing)
        layout.nameColumn = span(from: content.minX, to: trailing)
        if isRightToLeft { layout.mirror(in: content) }
        return layout
    }

    private static func width(of text: String, in font: UIFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

struct ProcessListColumnLayout {
    var icon = CGRect.zero
    var name = CGRect.zero
    // The icon and the name together, which the Name heading spans.
    var nameColumn = CGRect.zero
    var columns: [(column: ProcessColumn, frame: CGRect)] = []

    fileprivate mutating func mirror(in content: CGRect) {
        func mirrored(_ rect: CGRect) -> CGRect {
            var rect = rect
            rect.origin.x = content.minX + content.maxX - rect.maxX
            return rect
        }
        icon = mirrored(icon)
        name = mirrored(name)
        nameColumn = mirrored(nameColumn)
        columns = columns.map { ($0.column, mirrored($0.frame)) }
    }
}
