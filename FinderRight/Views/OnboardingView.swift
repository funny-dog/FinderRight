import SwiftUI

struct OnboardingView: View {
    /// 由 AppKit 宿主（NSWindow）注入的关闭回调
    var onClose: () -> Void = {}
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var currentStep = 0

    private let totalSteps = 3

    var body: some View {
        ZStack {
            // 背景渐变
            LinearGradient(
                colors: [
                    Color(nsColor: .controlBackgroundColor),
                    Color.blue.opacity(0.05),
                    Color.purple.opacity(0.05),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // 内容区域
                TabView(selection: $currentStep) {
                    WelcomeStep()
                        .tag(0)

                    EnableExtensionStep()
                        .tag(1)

                    CompletionStep()
                        .tag(2)
                }
                .tabViewStyle(.automatic)
                .animation(.easeInOut(duration: 0.3), value: currentStep)

                // 底部导航
                HStack {
                    // 步骤指示器
                    HStack(spacing: 8) {
                        ForEach(0..<totalSteps, id: \.self) { index in
                            Circle()
                                .fill(index == currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                                .frame(width: 8, height: 8)
                                .animation(.easeInOut(duration: 0.2), value: currentStep)
                        }
                    }

                    Spacer()

                    // 导航按钮
                    HStack(spacing: 12) {
                        if currentStep > 0 {
                            Button("上一步") {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    currentStep -= 1
                                }
                            }
                            .buttonStyle(.bordered)
                        }

                        if currentStep < totalSteps - 1 {
                            Button("下一步") {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    currentStep += 1
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button("开始使用") {
                                hasCompletedOnboarding = true
                                onClose()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 30)
            }
        }
        .frame(width: 600, height: 500)
    }
}

// MARK: - Step 1: 欢迎页

struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // 应用图标
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.blue.opacity(0.2), .purple.opacity(0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 120, height: 120)
                    .blur(radius: 20)

                Image(systemName: "contextualmenu.and.cursorarrow")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }

            // 标题
            VStack(spacing: 8) {
                Text("欢迎使用 FinderRight")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("增强你的 Finder 右键菜单")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }

            // 功能列表
            VStack(alignment: .leading, spacing: 16) {
                FeatureHighlight(
                    icon: "terminal.fill",
                    color: .blue,
                    title: "快速打开终端",
                    description: "在任意目录一键打开终端或编辑器"
                )
                FeatureHighlight(
                    icon: "doc.on.doc.fill",
                    color: .orange,
                    title: "高效文件操作",
                    description: "复制路径、新建文件、压缩等常用操作"
                )
                FeatureHighlight(
                    icon: "slider.horizontal.3",
                    color: .purple,
                    title: "完全可定制",
                    description: "自由选择需要的功能，隐藏不需要的"
                )
            }
            .padding(.horizontal, 60)

            Spacer()
        }
        .padding()
    }
}

struct FeatureHighlight: View {
    let icon: String
    let color: Color
    let title: LocalizedStringKey
    let description: LocalizedStringKey

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(color)
                .frame(width: 36, height: 36)
                .background(color.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Step 2: 启用扩展

struct EnableExtensionStep: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "puzzlepiece.extension.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 56, height: 56)
                .foregroundStyle(
                    LinearGradient(
                        colors: [.green, .mint],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            VStack(spacing: 8) {
                Text("启用 Finder 扩展")
                    .font(.title)
                    .fontWeight(.bold)

                Text("需要在系统设置中启用 FinderRight 扩展")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            // 步骤说明
            VStack(alignment: .leading, spacing: 16) {
                StepInstruction(
                    number: 1,
                    text: "点击下方按钮打开系统设置"
                )
                StepInstruction(
                    number: 2,
                    text: "在「扩展」列表中找到 FinderRight"
                )
                StepInstruction(
                    number: 3,
                    text: "勾选启用 Finder 扩展"
                )
            }
            .padding(.horizontal, 80)

            // 打开系统设置按钮
            Button {
                openExtensionsPreferences()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gear")
                    Text("打开系统设置")
                }
                .frame(minWidth: 180)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("完成后点击「下一步」继续")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()
        }
        .padding()
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
            Text("\(number)")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .frame(width: 24, height: 24)
                .background(Color.accentColor)
                .clipShape(Circle())

            Text(text)
                .font(.body)
        }
    }
}

// MARK: - Step 3: 完成

struct CompletionStep: View {
    @State private var showCheckmark = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // 动画勾选
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.1))
                    .frame(width: 100, height: 100)

                Image(systemName: "checkmark.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .foregroundColor(.green)
                    .scaleEffect(showCheckmark ? 1.0 : 0.5)
                    .opacity(showCheckmark ? 1.0 : 0.0)
                    .animation(.spring(response: 0.5, dampingFraction: 0.6), value: showCheckmark)
            }

            VStack(spacing: 8) {
                Text("一切就绪！")
                    .font(.title)
                    .fontWeight(.bold)

                Text("FinderRight 已准备好为你服务")
                    .font(.body)
                    .foregroundColor(.secondary)
            }

            // 右键菜单预览
            VStack(spacing: 0) {
                Text("右键菜单预览")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 8)

                VStack(spacing: 0) {
                    MenuPreviewItem(icon: "terminal", text: "在终端中打开")
                    Divider().padding(.horizontal, 12)
                    MenuPreviewItem(icon: "curlybraces", text: "在 VS Code 中打开")
                    Divider().padding(.horizontal, 12)
                    MenuPreviewItem(icon: "doc.on.doc", text: "复制路径")
                    Divider().padding(.horizontal, 12)
                    MenuPreviewItem(icon: "doc.badge.plus", text: "新建文件")
                }
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.regularMaterial)
                        .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
                )
                .frame(width: 220)
            }

            Spacer()
        }
        .padding()
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
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 16)
            Text(text)
                .font(.callout)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
