import UIKit

// Everything a record carries, for the sheet that opens when its row is tapped.
final class RowInspectionViewController: UITableViewController {
    private let inspection: DetailRowInspection

    init(inspection: DetailRowInspection) {
        self.inspection = inspection
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = inspection.title
        navigationItem.largeTitleDisplayMode = .never
        let copy = UIBarButtonItem(
            image: UIImage(systemName: "doc.on.doc"),
            style: .plain,
            target: self,
            action: #selector(copyAll)
        )
        copy.accessibilityLabel = String(localized: "Copy")
        navigationItem.leftBarButtonItem = copy
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "Done"),
            style: .done,
            target: self,
            action: #selector(close)
        )
        tableView.allowsSelection = false
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        inspection.fields.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let identifier = "field"
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: identifier)
        let field = inspection.fields[indexPath.row]
        // The label reads as a caption above its value.
        cell.textLabel?.text = field.label
        cell.textLabel?.font = .preferredFont(forTextStyle: .caption1)
        cell.textLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.text = field.value
        cell.detailTextLabel?.font = field.isMonospaced
            ? .inspector(.callout, design: .monospaced)
            : .preferredFont(forTextStyle: .callout)
        cell.detailTextLabel?.textColor = .label
        cell.detailTextLabel?.numberOfLines = 0
        for label in [cell.textLabel, cell.detailTextLabel] {
            label?.adjustsFontForContentSizeCategory = true
        }
        // Read as one row: the caption names the row and the text under it is
        // what that row says, rather than two fragments in a row of their own.
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = field.label
        cell.accessibilityValue = field.value
        return cell
    }

    override func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        .copy(inspection.fields[indexPath.row].value)
    }

    @objc private func copyAll() {
        UIPasteboard.general.string = inspection.text
    }

    @objc private func close() {
        dismiss(animated: true)
    }
}
