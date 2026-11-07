import SwiftUI
import AppKit
import FinderRightKit

/// 单个功能开关行：前导图标 + 名称与说明 + 开关。直接读写 SharedConfig，开关状态即时持久化。
/// trailing：可在开关右侧插入额外控件（如"打开"按钮），保持各行开关位置对齐。
struct FeatureToggleRow<Trailing: View>: View {
    let feature: MenuFeature
    @FRState private var isEnabled: Bool
    private let trailing: Trailing

    init(feature: MenuFeature, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.feature = feature
        _isEnabled = FRState(wrappedValue: SharedConfig.shared.isActionEnabled(feature.id))
        self.trailing = trailing()
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

            trailing

            FRSwitch(label: LocalizedStringKey(feature.nameKey), isOn: Binding(
                get: { isEnabled },
                set: { newValue in
                    isEnabled = newValue
                    SharedConfig.shared.setActionEnabled(feature.id, enabled: newValue)
                    if MenuFeatureCatalog.developerFeatureIds.contains(feature.id) {
                        if ServiceShortcutSync.run() { NSUpdateDynamicServices() }
                        FinderShortcutInterceptor.shared.refresh()
                    }
                }
            ))
        }
    }
}
