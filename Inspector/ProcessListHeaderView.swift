import UIKit

// Above the rows, a heading over each column. A heading sorts the list by
// its column, and the one it is sorted by is tinted and carries an arrow, as
// in a detail table. What the list holds is the navigation bar's subtitle.
final class ProcessListHeaderView: UITableViewHeaderFooterView {
    static let reuseIdentifier = "header"

    var sort: (ProcessSortOrder) -> Void {
        get { headings.sort }
        set { headings.sort = newValue }
    }

    private let headings = ProcessColumnHeadingsView()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        headings.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(headings)
        let margins = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            headings.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            headings.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            headings.topAnchor.constraint(equalTo: margins.topAnchor),
            headings.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(sortOrder: ProcessSortOrder, metrics: ProcessListMetrics) {
        headings.configure(sortOrder: sortOrder, metrics: metrics)
    }

    /// Lines the headings up with the rows below: `insets` are the distances
    /// from the sides of `table` to a row's content area.
    func alignColumns(to insets: UIEdgeInsets, in table: UIView) {
        headings.align(to: insets, in: table)
    }
}

private final class ProcessColumnHeadingsView: UIView {
    var sort: (ProcessSortOrder) -> Void = { _ in }

    private struct Heading {
        let order: ProcessSortOrder
        let column: ProcessColumn?
        let button = UIButton(type: .system)
    }

    // The name heading first, then the figures, in reading order.
    private let headings: [Heading] = [Heading(order: .name, column: nil)]
        + ProcessColumn.allCases.map { Heading(order: $0.sortOrder, column: $0) }
    private var metrics: ProcessListMetrics?
    private var sortOrder: ProcessSortOrder?
    private var rowInsets: UIEdgeInsets?
    private weak var table: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        for heading in headings {
            let button = heading.button
            let title = heading.column?.title ?? String(localized: "Name")
            button.setTitle(title, for: .normal)
            button.titleLabel?.lineBreakMode = .byClipping
            button.addTarget(self, action: #selector(headingTapped(_:)), for: .touchUpInside)
            // Voice Control accepts the heading as written; VoiceOver reads
            // the sort order's full name, as the Sort By menu words it.
            button.accessibilityLabel = heading.order.label
            button.accessibilityUserInputLabels = [title, heading.order.label]
            addSubview(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: metrics?.titleRowHeight ?? 0)
    }

    func configure(sortOrder: ProcessSortOrder, metrics: ProcessListMetrics) {
        if metrics !== self.metrics {
            self.metrics = metrics
            for heading in headings {
                heading.button.titleLabel?.font = metrics.titleFont
            }
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
        guard sortOrder != self.sortOrder else { return }
        self.sortOrder = sortOrder
        applySortOrder()
    }

    func align(to insets: UIEdgeInsets, in table: UIView) {
        guard insets != rowInsets || table !== self.table else { return }
        rowInsets = insets
        self.table = table
        setNeedsLayout()
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        applySortOrder()
    }

    private func applySortOrder() {
        for heading in headings {
            let isSorted = heading.order == sortOrder
            let button = heading.button
            button.setImage(
                isSorted
                    ? UIImage(
                        systemName: heading.order.isAscending ? "chevron.up" : "chevron.down",
                        withConfiguration: ProcessListMetrics.arrowConfiguration
                    )
                    : nil,
                for: .normal
            )
            button.tintColor = isSorted ? tintColor : .secondaryLabel
            // The arrow is the only cue for the direction, and it is drawn,
            // not spoken. Each column sorts one way only, so a tap on the
            // sorted heading changes nothing and earns no hint.
            button.accessibilityValue = isSorted
                ? (heading.order.isAscending
                    ? String(localized: "Sorted ascending")
                    : String(localized: "Sorted descending"))
                : nil
            button.accessibilityHint = isSorted
                ? nil
                : String(localized: "Sorts the list by this column")
            button.accessibilityTraits = isSorted ? [.button, .selected] : .button
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let metrics else { return }
        // The rows' content area, carried over from the table, so the
        // headings follow the rows whatever margins this header was given.
        var content = bounds
        if let table, let rowInsets {
            let tableBounds = table.convert(table.bounds, to: self)
            content.origin.x = tableBounds.minX + rowInsets.left
            content.size.width = max(0, tableBounds.width - rowInsets.left - rowInsets.right)
        }
        let isRightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let layout = metrics.columnLayout(in: content, isRightToLeft: isRightToLeft)
        for heading in headings {
            let button = heading.button
            let frame: CGRect?
            if let column = heading.column {
                frame = layout.columns.first { $0.column == column }?.frame
            } else {
                frame = layout.nameColumn
            }
            guard let frame else {
                button.isHidden = true
                continue
            }
            button.isHidden = false
            button.frame = frame
            // The name heading starts where the icons do, its arrow after
            // it. A figure's heading ends where its figures end, so its arrow
            // goes in front.
            let isLeading = heading.column == nil
            button.contentHorizontalAlignment = isLeading == isRightToLeft ? .right : .left
            button.semanticContentAttribute = isLeading == isRightToLeft
                ? .forceLeftToRight
                : .forceRightToLeft
        }
    }

    @objc private func headingTapped(_ sender: UIButton) {
        guard let heading = headings.first(where: { $0.button === sender }) else { return }
        sort(heading.order)
    }
}

private extension ProcessSortOrder {
    // The direction areInOrder sorts in, which the arrow shows.
    var isAscending: Bool {
        switch self {
        case .pid, .name: true
        case .cpu, .memory, .threads: false
        }
    }
}
