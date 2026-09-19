import UIKit

// UIContentUnavailableConfiguration starts at iOS 17. This small equivalent
// keeps loading, empty, failure, and search states consistent on every system
// the app runs on. It is meant to be a table's backgroundView.
final class InspectorUnavailableView: UIView {
    enum Content: Equatable {
        case loading(String?)
        case message(symbolName: String, title: String, description: String?, actionTitle: String?)
    }

    let content: Content
    private let action: () -> Void

    init(_ content: Content, action: @escaping () -> Void = {}) {
        self.content = content
        self.action = action
        super.init(frame: .zero)
        backgroundColor = .systemBackground

        let stack = UIStackView(arrangedSubviews: arrangedViews())
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let width = stack.widthAnchor.constraint(equalToConstant: 420)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: safeAreaLayoutGuide.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: safeAreaLayoutGuide.centerYAnchor),
            stack.leadingAnchor.constraint(
                greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor,
                constant: 24
            ),
            width,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func arrangedViews() -> [UIView] {
        switch content {
        case .loading(let text):
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            guard let text else { return [spinner] }
            return [spinner, label(text, style: .subheadline, color: .secondaryLabel)]
        case .message(let symbolName, let title, let description, let actionTitle):
            let titleFont = UIFont.inspector(.title3, weight: .semibold)
            let symbol = UIImageView(
                image: UIImage(
                    systemName: symbolName,
                    withConfiguration: UIImage.SymbolConfiguration(font: titleFont)
                )
            )
            symbol.tintColor = .label
            let titleLabel = label(title, style: .title3, color: .label)
            titleLabel.font = titleFont
            let heading = UIStackView(arrangedSubviews: [symbol, titleLabel])
            heading.spacing = 6
            heading.alignment = .center
            var views: [UIView] = [heading]
            if let description {
                views.append(label(description, style: .body, color: .secondaryLabel))
            }
            if let actionTitle {
                let button = UIButton(type: .system)
                button.setTitle(actionTitle, for: .normal)
                button.titleLabel?.font = .preferredFont(forTextStyle: .body)
                button.titleLabel?.adjustsFontForContentSizeCategory = true
                button.addTarget(self, action: #selector(performAction), for: .touchUpInside)
                views.append(button)
            }
            return views
        }
    }

    private func label(_ text: String, style: UIFont.TextStyle, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }

    @objc private func performAction() {
        action()
    }
}

extension UITableView {
    // Swaps the background only when what it says changes, so a live sample
    // doesn't restart the spinner or rebuild the view.
    func setUnavailableContent(
        _ content: InspectorUnavailableView.Content?,
        action: @escaping () -> Void = {}
    ) {
        if (backgroundView as? InspectorUnavailableView)?.content == content { return }
        backgroundView = content.map { InspectorUnavailableView($0, action: action) }
    }
}
