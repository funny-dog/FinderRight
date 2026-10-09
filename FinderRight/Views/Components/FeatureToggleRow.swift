import SwiftUI
import FinderRightKit

/// 单个功能开关行：前导图标 + 名称与说明 + 开关。直接读写 SharedConfig，开关状态即时持久化。
struct FeatureToggleRow: View {
    let feature: MenuFeature
    @FRState private var isEnabled: Bool

    init(feature: MenuFeature) {
        self.feature = feature
        _isEnabled = FRState(wrappedValue: SharedConfig.shared.isActionEnabled(feature.id))
    }

    var body: some View {
        HStack(spacing: 12) {
            FRIconChip(systemName: feature.systemImage)

            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(feature.nameKey))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(FRTheme.text)
                Text(LocalizedStringKey(feature.descriptionKey))
                    .font(.system(size: 12))
                    .foregroundColor(FRTheme.mute)
            }

            Spacer(minLength: 12)

            FRSwitch(label: LocalizedStringKey(feature.nameKey), isOn: Binding(
                get: { isEnabled },
                set: { newValue in
                    isEnabled = newValue
                    SharedConfig.shared.setActionEnabled(feature.id, enabled: newValue)
                }
            ))
        }
    }
}
