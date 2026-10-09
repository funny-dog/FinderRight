import SwiftUI

struct OnboardingView: View {
    /// 由 AppKit 宿主（NSWindow）注入的关闭回调
    var onClose: () -> Void = {}
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @FRState private var currentStep = 0

    private let totalSteps = 5

    var body: some View {
        ZStack {
            FRTheme.window
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // 顶部分段进度条（为红绿灯留出位置）
                HStack(spacing: 6) {
                    ForEach(0..<totalSteps, id: \.self) { index in
                        Capsule()
                            .fill(index <= currentStep ? FRTheme.accent : FRTheme.mute.opacity(0.25))
                            .frame(height: 4)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.top, 44)
                .animation(.easeInOut(duration: 0.25), value: currentStep)

                // 内容区域：同一时刻只渲染当前步骤
                ZStack {
                    switch currentStep {
                    case 0:
                        WelcomeStep()
                    case 1:
                        EnableExtensionStep()
                    case 2:
                        PermissionStep(
                            icon: "externaldrive.fill.badge.checkmark",
                            title: "授予完全磁盘访问（推荐）",
                            subtitle: "用于在「文稿」「桌面」「下载」等受保护目录中执行操作。可以先跳过，之后在「设置 → 通用」中授权。"
                        ) {
                            FRCard { FullDiskAccessView() }
                        }
                    case 3:
                        PermissionStep(
                            icon: "accessibility",
                            title: "授予辅助功能（可选）",
                            subtitle: "仅用于无闪烁地切换隐藏文件，其他功能不需要它。可以先跳过，之后在「设置 → 通用」中授权。"
                        ) {
                            FRCard { AccessibilityView() }
                        }
                    default:
                        CompletionStep()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
                .id(currentStep)

                // 底部导航
                HStack {
                    Text(verbatim: "\(currentStep + 1) / \(totalSteps)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(FRTheme.mute)

                    Spacer()

                    HStack(spacing: 10) {
                        if currentStep > 0 {
                            Button("上一步") {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    currentStep -= 1
                                }
                            }
                            .buttonStyle(.frSecondary)
                        }

                        if currentStep < totalSteps - 1 {
                            Button("下一步") {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    currentStep += 1
                                }
                            }
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.frPrimary)
                        } else {
                            Button("开始使用") {
                                hasCompletedOnboarding = true
                                onClose()
                            }
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(.frPrimary)
                        }
                    }
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 28)
            }
        }
        .frame(width: 600, height: 500)
    }
}

// MARK: - Step 1: 欢迎页

struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)

            Text("欢迎使用 FinderRight")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(FRTheme.text)
                .padding(.top, 14)

            Text("增强你的 Finder 右键菜单")
                .font(.system(size: 15))
                .foregroundColor(FRTheme.mute)
                .padding(.top, 4)

            HStack(spacing: 12) {
                FeatureHighlight(
                    icon: "terminal",
                    title: "快速打开终端",
                    description: "在任意目录一键打开终端或编辑器"
                )
                FeatureHighlight(
                    icon: "doc.on.doc",
                    title: "高效文件操作",
                    description: "复制路径、新建文件、压缩等常用操作"
                )
                FeatureHighlight(
                    icon: "slider.horizontal.3",
                    title: "完全可定制",
                    description: "自由选择需要的功能，隐藏不需要的"
                )
            }
            .padding(.horizontal, 40)
            .padding(.top, 26)

            Spacer(minLength: 0)
        }
    }
}

struct FeatureHighlight: View {
    let icon: String
    let title: LocalizedStringKey
    let description: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FRIconChip(systemName: icon)

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(FRTheme.text)
                .padding(.top, 10)
            Text(description)
                .font(.system(size: 12))
                .foregroundColor(FRTheme.mute)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(FRTheme.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(FRTheme.border, lineWidth: 1))
    }
}

// MARK: - Step 2: 启用扩展

struct EnableExtensionStep: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            FRIconChip(systemName: "puzzlepiece.extension.fill", size: 56)

            Text("启用 Finder 扩展")
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(FRTheme.text)
                .padding(.top, 16)

            Text("需要在系统设置中启用 FinderRight 扩展")
                .font(.system(size: 14))
                .foregroundColor(FRTheme.mute)
                .multilineTextAlignment(.center)
                .padding(.top, 4)

            // 步骤说明
            FRCard {
                StepInstruction(number: 1, text: "点击下方按钮打开系统设置")
                FRDivider()
                StepInstruction(number: 2, text: "在「扩展」列表中找到 FinderRight")
                FRDivider()
                StepInstruction(number: 3, text: "勾选启用 Finder 扩展")
            }
            .frame(width: 360)
            .padding(.top, 22)

            // 打开系统设置按钮
            Button {
                openExtensionsPreferences()
            } label: {
                Label("打开系统设置", systemImage: "gearshape")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.frPrimary)
            .padding(.top, 20)

            Text("完成后点击「下一步」继续")
                .font(.system(size: 12))
                .foregroundColor(FRTheme.mute)
                .padding(.top, 10)

            Spacer(minLength: 0)
        }
    }

    private func openExtensionsPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct StepInstruction: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(spacing: 12) {
            Text(verbatim: "\(number)")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(FRTheme.onAccent)
                .frame(width: 22, height: 22)
                .background(Circle().fill(FRTheme.accent))

            Text(text)
                .font(.system(size: 13))
                .foregroundColor(FRTheme.text)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

// MARK: - Step 3/4: 授权（完全磁盘访问、辅助功能）

/// 授权步骤的外壳：标题区 + 设置页同款授权视图（状态、跳转按钮、步骤说明都复用，不另写一套）
struct PermissionStep<Content: View>: View {
    let icon: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        // 展开「授权步骤说明」后内容可能超出窗口高度，放进滚动视图
        ScrollView {
            VStack(spacing: 0) {
                FRIconChip(systemName: icon, size: 48)

                Text(title)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(FRTheme.text)
                    .padding(.top, 14)

                Text(subtitle)
                    .font(.system(size: 13.5))
                    .foregroundColor(FRTheme.mute)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 50)
                    .padding(.top, 6)

                content
                    .frame(maxWidth: 440)
                    .padding(.top, 20)
            }
            .padding(.top, 26)
            .padding(.horizontal, 40)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Step 5: 完成

struct CompletionStep: View {
    @FRState private var showCheckmark = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            // 动画勾选
            ZStack {
                Circle()
                    .fill(FRTheme.selection)
                    .frame(width: 96, height: 96)

                Image(systemName: "checkmark")
                    .font(.system(size: 40, weight: .bold))
                    .foregroundColor(FRTheme.accentText)
                    .scaleEffect(showCheckmark ? 1.0 : 0.5)
                    .opacity(showCheckmark ? 1.0 : 0.0)
                    .animation(.spring(response: 0.5, dampingFraction: 0.6), value: showCheckmark)
            }

            Text("一切就绪！")
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(FRTheme.text)
                .padding(.top, 16)

            Text("FinderRight 已准备好为你服务")
                .font(.system(size: 14))
                .foregroundColor(FRTheme.mute)
                .padding(.top, 4)

            // 右键菜单预览
            VStack(spacing: 8) {
                Text("右键菜单预览")
                    .font(.system(size: 12))
                    .foregroundColor(FRTheme.mute)

                FRCard {
                    MenuPreviewItem(icon: "terminal", text: "在终端中打开")
                    FRDivider()
                    MenuPreviewItem(icon: "curlybraces", text: "在 VS Code 中打开")
                    FRDivider()
                    MenuPreviewItem(icon: "doc.on.doc", text: "复制路径")
                    FRDivider()
                    MenuPreviewItem(icon: "doc.badge.plus", text: "新建文件")
                }
                .frame(width: 240)
            }
            .padding(.top, 22)

            Spacer(minLength: 0)
        }
        .onAppear {
            showCheckmark = true
        }
    }
}

struct MenuPreviewItem: View {
    let icon: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(FRTheme.accentText)
                .frame(width: 16)
            Text(text)
                .font(.system(size: 13))
                .foregroundColor(FRTheme.text)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
