import UIKit

final class ProcessRowCell: UITableViewCell {
    static let reuseIdentifier = "process"

    private let iconView = ProcessApplicationIconView()
    private let nameLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let cpuLabel = UILabel()
    private let memoryLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        accessoryType = .disclosureIndicator
        // One element for the whole row, labelled in configure(with:). Left to
        // itself the cell strings the four labels together, so the subtitle's
        // separators are spoken and the two figures arrive with no unit.
        isAccessibilityElement = true

        nameLabel.font = .preferredFont(forTextStyle: .body)
        subtitleLabel.font = .preferredFont(forTextStyle: .footnote)
        subtitleLabel.textColor = .secondaryLabel
        cpuLabel.font = .inspector(.body, design: .monospacedDigit)
        memoryLabel.font = .inspector(.footnote, design: .monospacedDigit)
        memoryLabel.textColor = .secondaryLabel
        for label in [nameLabel, subtitleLabel, cpuLabel, memoryLabel] {
            label.adjustsFontForContentSizeCategory = true
        }
        // The numbers keep their width; a long name gives way instead.
        for label in [cpuLabel, memoryLabel] {
            label.textAlignment = .natural
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
            label.setContentHuggingPriority(.required, for: .horizontal)
        }

        let names = UIStackView(arrangedSubviews: [nameLabel, subtitleLabel])
        names.axis = .vertical
        names.spacing = 2
        let numbers = UIStackView(arrangedSubviews: [cpuLabel, memoryLabel])
        numbers.axis = .vertical
        numbers.alignment = .trailing
        numbers.spacing = 2
        let content = UIStackView(arrangedSubviews: [iconView, names, numbers])
        content.alignment = .center
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(content)

        let margins = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: ProcessApplicationIconView.size),
            iconView.heightAnchor.constraint(equalToConstant: ProcessApplicationIconView.size),
            content.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            content.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            content.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(with row: ProcessRow) {
        iconView.executablePath = row.isApp ? row.record.executablePath : nil
        nameLabel.text = row.displayName
        let details = [
            "PID \(row.record.pid)",
            InspectorFormat.userName(row.record.userID),
            String(localized: "\(Int(row.record.threadCount)) threads"),
        ]
        subtitleLabel.text = details.joined(separator: " · ")
        let cpu = InspectorFormat.percent(row.cpuFraction)
        let memory = InspectorFormat.memoryBytes(row.record.physicalFootprint)
        cpuLabel.text = cpu
        cpuLabel.textColor = row.cpuFraction > 0.005 ? .label : .secondaryLabel
        memoryLabel.text = memory
        // What the row is goes in the label, what it currently measures in the
        // value, so a live sample re-announces the figures without repeating
        // the name. The numbers are named because on their own they are two
        // bare quantities.
        accessibilityLabel = ([row.displayName] + details).joined(separator: ", ")
        accessibilityValue = [
            "\(String(localized: "CPU")) \(cpu)",
            "\(String(localized: "Memory")) \(memory)",
        ].joined(separator: ", ")
    }
}
