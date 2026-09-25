import UIKit

// One process as a line of columns: icon and name, then figures at the
// widths ProcessListMetrics measured, so they line up under the headings.
// Laid out by hand: a live sample redraws every visible row, and fixed
// frames make that a matter of setting text.
final class ProcessRowCell: UITableViewCell {
    static let reuseIdentifier = "process"

    /// Called after every layout, with the row's geometry settled, so the
    /// headings above can line up with it.
    var didLayout: (ProcessRowCell) -> Void = { _ in }

    private let iconView = ProcessApplicationIconView()
    private let nameLabel = UILabel()
    private let pidLabel = UILabel()
    private let cpuLabel = UILabel()
    private let memoryLabel = UILabel()
    private let threadsLabel = UILabel()
    private var metrics: ProcessListMetrics?

    // CPU use, as a fraction of one core, from which the figure stops
    // reading as idle, then as ordinary, then as busy. A process spinning a
    // whole core, which is what a stuck one does, shows red.
    private static let activeCPU = 0.005
    private static let busyCPU = 0.5
    private static let saturatedCPU = 0.9

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        // One element for the whole row, labelled in configure(with:). Left to
        // itself the cell reads each figure as a separate bare number.
        isAccessibilityElement = true

        // The middle goes rather than the end: helpers share long prefixes,
        // like com.apple.WebKit.WebContent and com.apple.WebKit.Networking.
        nameLabel.lineBreakMode = .byTruncatingMiddle
        pidLabel.textColor = .secondaryLabel
        threadsLabel.textColor = .secondaryLabel
        // A figure wider than its column's sample (a thousand threads) shrinks
        // to fit rather than losing digits.
        for label in [pidLabel, cpuLabel, memoryLabel, threadsLabel] {
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.7
            label.baselineAdjustment = .alignBaselines
        }
        for view in [iconView, nameLabel, pidLabel, cpuLabel, memoryLabel, threadsLabel] {
            contentView.addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The row's content area, between its margins, in contentView's space.
    var columnsRect: CGRect {
        contentView.bounds.inset(by: contentView.layoutMargins)
    }

    func configure(with row: ProcessRow, metrics: ProcessListMetrics) {
        if metrics !== self.metrics {
            self.metrics = metrics
            nameLabel.font = metrics.nameFont
            for label in [pidLabel, cpuLabel, memoryLabel, threadsLabel] {
                label.font = metrics.valueFont
            }
            setNeedsLayout()
        }
        iconView.executablePath = row.isApp ? row.record.executablePath : nil
        nameLabel.text = row.displayName
        let pid = "PID \(row.record.pid)"
        let threads = String(localized: "\(Int(row.record.threadCount)) threads")
        let cpu = InspectorFormat.percent(row.cpuFraction)
        let memory = InspectorFormat.memoryColumn(row.record.physicalFootprint)
        // Under a heading a column needs only the number; stacked, there is
        // no heading, so each figure says what it is.
        pidLabel.text = metrics.isStacked ? pid : "\(row.record.pid)"
        threadsLabel.text = metrics.isStacked ? threads : "\(row.record.threadCount)"
        cpuLabel.text = cpu
        cpuLabel.textColor = Self.cpuColor(row.cpuFraction)
        memoryLabel.text = memory
        // Stacked figures sit side by side at their own widths.
        if metrics.isStacked { setNeedsLayout() }

        // What the row is goes in the label, what it currently measures in the
        // value, so a live sample re-announces the figures without repeating
        // the name. The numbers are named because on their own they are two
        // bare quantities.
        accessibilityLabel = [
            row.displayName,
            pid,
            InspectorFormat.userName(row.record.userID),
            threads,
        ].joined(separator: ", ")
        accessibilityValue = [
            "\(String(localized: "CPU")) \(cpu)",
            "\(String(localized: "Memory")) \(memory)",
        ].joined(separator: ", ")
    }

    private static func cpuColor(_ fraction: Double) -> UIColor {
        if fraction >= saturatedCPU { return .systemRed }
        if fraction >= busyCPU { return .systemOrange }
        if fraction >= activeCPU { return .label }
        return .secondaryLabel
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let metrics else { return }
        if metrics.isStacked {
            layoutStacked(metrics)
        } else {
            layoutColumns(metrics)
        }
        didLayout(self)
    }

    private func layoutColumns(_ metrics: ProcessListMetrics) {
        var content = columnsRect
        content.origin.y = contentView.bounds.minY
        content.size.height = contentView.bounds.height
        let layout = metrics.columnLayout(
            in: content,
            isRightToLeft: effectiveUserInterfaceLayoutDirection == .rightToLeft
        )
        iconView.frame = centered(height: metrics.iconSize, in: layout.icon)
        // Names and figures differ in size, so they share a baseline rather
        // than a center line.
        nameLabel.frame = centered(height: ceil(metrics.nameFont.lineHeight), in: layout.name)
        let baseline = nameLabel.frame.minY + metrics.nameFont.ascender
        let valueY = pixelAligned(baseline - metrics.valueFont.ascender)
        let valueHeight = ceil(metrics.valueFont.lineHeight)
        let alignment: NSTextAlignment = effectiveUserInterfaceLayoutDirection == .rightToLeft
            ? .left
            : .right
        var hidden = Set(ProcessColumn.allCases)
        for (column, frame) in layout.columns {
            let label = label(for: column)
            label.frame = CGRect(x: frame.minX, y: valueY, width: frame.width, height: valueHeight)
            label.textAlignment = alignment
            hidden.remove(column)
        }
        for column in ProcessColumn.allCases {
            label(for: column).isHidden = hidden.contains(column)
        }
    }

    // The name on its own line, then CPU and memory, then PID and threads,
    // each figure as wide as its text.
    private func layoutStacked(_ metrics: ProcessListMetrics) {
        let content = columnsRect
        let isRightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        var icon = CGRect(
            x: content.minX,
            y: pixelAligned(contentView.bounds.midY - metrics.iconSize / 2),
            width: metrics.iconSize,
            height: metrics.iconSize
        )
        var text = content
        text.origin.x = icon.maxX + metrics.iconSpacing
        text.size.width = max(0, content.maxX - text.minX)
        if isRightToLeft {
            icon.origin.x = content.minX + content.maxX - icon.maxX
            text.origin.x = content.minX + content.maxX - text.maxX
        }
        iconView.frame = icon

        var y = contentView.bounds.minY + ProcessListMetrics.stackedPadding
        let nameHeight = ceil(metrics.nameFont.lineHeight)
        nameLabel.frame = CGRect(x: text.minX, y: y, width: text.width, height: nameHeight)
        nameLabel.textAlignment = .natural
        y += nameHeight
        let valueHeight = ceil(metrics.valueFont.lineHeight)
        for line in [[cpuLabel, memoryLabel], [pidLabel, threadsLabel]] {
            y += ProcessListMetrics.lineSpacing
            var offset: CGFloat = 0
            for label in line {
                let width = min(ceil(label.intrinsicContentSize.width), max(0, text.width - offset))
                let x = isRightToLeft ? text.maxX - offset - width : text.minX + offset
                label.frame = CGRect(x: x, y: y, width: width, height: valueHeight)
                label.textAlignment = .natural
                label.isHidden = false
                offset += width + metrics.columnSpacing
            }
            y += valueHeight
        }
    }

    private func label(for column: ProcessColumn) -> UILabel {
        switch column {
        case .pid: pidLabel
        case .cpu: cpuLabel
        case .memory: memoryLabel
        case .threads: threadsLabel
        }
    }

    private func centered(height: CGFloat, in rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: pixelAligned(rect.midY - height / 2), width: rect.width, height: height)
    }

    private func pixelAligned(_ value: CGFloat) -> CGFloat {
        let scale = max(traitCollection.displayScale, 1)
        return (value * scale).rounded() / scale
    }
}
