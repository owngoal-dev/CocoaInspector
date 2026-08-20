import SwiftUI
import UIKit

// ContentUnavailableView starts at iOS 17. This small equivalent keeps empty,
// failure, and search states consistent while the app targets iOS 16.
struct InspectorUnavailableView<LabelContent: View, Description: View, Actions: View>: View {
    private let label: LabelContent
    private let description: Description
    private let actions: Actions

    init(
        @ViewBuilder label: () -> LabelContent,
        @ViewBuilder description: () -> Description,
        @ViewBuilder actions: () -> Actions
    ) {
        self.label = label()
        self.description = description()
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 12) {
            label
                .font(.title3.weight(.semibold))
            description
                .foregroundStyle(.secondary)
            actions
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
}

extension InspectorUnavailableView where Actions == EmptyView {
    init(
        @ViewBuilder label: () -> LabelContent,
        @ViewBuilder description: () -> Description
    ) {
        self.init(label: label, description: description, actions: EmptyView.init)
    }
}

extension InspectorUnavailableView where Description == EmptyView, Actions == EmptyView {
    init(@ViewBuilder label: () -> LabelContent) {
        self.init(label: label, description: EmptyView.init, actions: EmptyView.init)
    }
}
