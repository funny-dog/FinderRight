import SwiftUI
import AppKit
import FinderRightKit

// MARK: - SettingsView

/// 设置窗口当前显示的标签页。由 finderright://settings/<页名> 链接驱动（例如右键「管理常用目录…」）
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var selectedTab: SettingsView.SettingsTab = .general
}

/// 设置窗口：左侧侧边栏导航 + 右侧卡片式内容。窗口为无标题栏样式，侧边栏延伸到红绿灯下方。
struct SettingsView: View {
    enum SettingsTab: String, CaseIterable {
        case general = "通用"
        case features = "功能"
        case newFile = "文件模板"
        case favorites = "常用目录"
        case shortcuts = "快捷键"
        case tools = "终端"
        case editors = "编辑器"
        case history = "操作历史"
        case permissions = "权限与扩展"
        case about = "关于"

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .features: return "slider.horizontal.3"
            case .favorites: return "folder"
            case .shortcuts: return "keyboard"
            case .newFile: return "doc.badge.plus"
            case .tools: return "terminal"
            case .editors: return "curlybraces"
            case .history: return "clock.arrow.circlepath"
            case .permissions: return "checkmark.shield"
            case .about: return "info.circle"
            }
        }

        /// finderright://settings/<urlName> 中使用的页名
        var urlName: String {
            switch self {
            case .general: return "general"
            case .features: return "features"
            case .favorites: return "favorites"
            case .shortcuts: return "shortcuts"
            case .newFile: return "newfile"
            case .tools: return "tools"
            case .editors: return "editors"
            case .history: return "history"
            case .permissions: return "permissions"
            case .about: return "about"
            }
        }
    }

    @ObservedObject private var navigation = SettingsNavigation.shared
    @AppStorage(FRThemeID.storageKey) private var themeRaw = FRThemeID.midnight.rawValue

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $navigation.selectedTab)

            Rectangle()
                .fill(FRTheme.border)
                .frame(width: 1)

            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(FRTheme.window)
        }
        // 主题色变化时整棵视图重建，让所有动态颜色按新主题重新取值
        .id(themeRaw)
        .frame(minWidth: 680, idealWidth: 780, maxWidth: .infinity,
               minHeight: 500, idealHeight: 620, maxHeight: .infinity)
        .background(FRTheme.window)
    }

    @ViewBuilder
    private var page: some View {
        switch navigation.selectedTab {
        case .general: GeneralTab()
        case .features: FeaturesTab()
        case .favorites: FavoritesTab()
        case .shortcuts: ShortcutsTab()
        case .newFile: NewFileTab()
        case .tools: ToolsTab()
        case .editors: EditorsTab()
        case .history: OperationHistoryView()
        case .permissions: PermissionsTab()
        case .about: AboutTab()
        }
    }
}

// MARK: - 侧边栏

private struct SettingsSidebar: View {
    @Binding var selection: SettingsView.SettingsTab

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 顶部留出红绿灯的位置
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 30, height: 30)
                Text(verbatim: "FinderRight")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(FRTheme.text)
            }
            .padding(.top, 46)
            .padding(.horizontal, 16)

            VStack(spacing: 2) {
                ForEach(SettingsView.SettingsTab.allCases, id: \.self) { tab in
                    SidebarItem(tab: tab, isSelected: selection == tab) {
                        selection = tab
                    }
                }
            }
            .padding(.top, 22)
            .padding(.horizontal, 10)

            Spacer(minLength: 0)

            Text(verbatim: "v\(UpdateChecker.shared.currentAppVersion)")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(FRTheme.mute)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
        .frame(width: 200)
        .frame(maxHeight: .infinity)
        .background(FRTheme.sidebar)
    }
}

private struct SidebarItem: View {
    let tab: SettingsView.SettingsTab
    let isSelected: Bool
    let action: () -> Void
    @FRState private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: 14))
                    .frame(width: 20)
                    .foregroundColor(isSelected ? FRTheme.accentText : FRTheme.mute)
                Text(LocalizedStringKey(tab.rawValue))
                    .font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? FRTheme.text : FRTheme.mute)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? FRTheme.selection : (isHovering ? FRTheme.hover : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
