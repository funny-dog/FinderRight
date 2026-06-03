import SwiftUI
import FinderRightKit

/// 单个功能开关行。直接读写 SharedConfig，开关状态即时持久化。
struct FeatureToggleRow: View {
    let feature: MenuFeature

    var body: some View {
        Toggle(isOn: Binding(
            get: { SharedConfig.shared.isActionEnabled(feature.id) },
            set: { SharedConfig.shared.setActionEnabled(feature.id, enabled: $0) }
        )) {
            HStack(spacing: 12) {
                Image(systemName: feature.systemImage)
                    .font(.body)
                    .foregroundColor(.accentColor)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(feature.nameKey))
                        .font(.body)
                    Text(LocalizedStringKey(feature.descriptionKey))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}
