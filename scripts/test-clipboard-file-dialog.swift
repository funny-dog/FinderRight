import FinderRightKit

// 只检查弹窗状态和后缀选择，不创建窗口或读写用户剪贴板。
@main
struct ClipboardFileDialogChecks {
    static func main() {
        let extensions = BuiltInFileTemplates.text.map(\.fileExtension)
        let model = FRDialogModel(title: "", message: "", symbol: "doc", tone: .normal, buttons: ["创建", "取消"],
                                  input: .file(initialName: "untitled", extensions: extensions, allowsCustomExtension: true))
        precondition(model.text == "untitled" && model.fileExtension == "txt")
        model.text = "报告"
        model.customExtension = "exe"
        for (index, ext) in extensions.enumerated() {
            model.selected = index
            precondition(model.fileExtension == ext, "固定类型不受自定义后缀影响")
            precondition(model.text == "报告", "切换类型保留用户填写的文件名")
        }
        var layoutChanges = 0
        model.onLayoutChange = { layoutChanges += 1 }
        model.selected = extensions.count
        precondition(layoutChanges == 1, "选择自定义时更新输入区布局")
        model.customExtension = " .yaml "
        precondition(model.fileExtension == "yaml")
        for ext in ["", ".", "../bad", "a/b", "bad\nname"] {
            model.customExtension = ext
            precondition(model.fileExtension == nil, "拒绝空后缀和路径穿越")
        }
        model.customExtension = "log"
        model.text = "../report"
        precondition(model.fileExtension == nil)
        model.text = "报告"
        model.selected = 0
        precondition(model.fileExtension == "txt", "返回固定类型后不沿用自定义后缀")

        let imageExtensions = ImageTargetFormat.allCases.map(\.fileExtension)
        let image = FRDialogModel(title: "", message: "", symbol: "photo", tone: .normal, buttons: ["创建"],
                                  input: .file(initialName: "untitled", extensions: imageExtensions, allowsCustomExtension: false))
        precondition(image.fileExtension == "png")
        for (index, ext) in imageExtensions.enumerated() {
            image.selected = index
            precondition(image.fileExtension == ext)
        }
        image.customExtension = "gif"
        image.selected = imageExtensions.count
        precondition(image.fileExtension == nil, "图片不能通过自定义后缀伪装格式")

        let text = FRDialogModel(title: "", message: "", symbol: "folder", tone: .normal, buttons: ["打开"],
                                 input: .text(initial: "~/Downloads", placeholder: "", accessibilityLabel: "路径"))
        precondition(text.text == "~/Downloads" && text.fileExtension == nil)
        let choice = FRDialogModel(title: "", message: "", symbol: "doc", tone: .normal, buttons: ["创建"],
                                   input: .choice(["TXT", "Markdown"], accessibilityLabel: "类型"))
        precondition(choice.selected == 0 && choice.fileExtension == nil)
        print("PASS: 剪贴板新建弹窗默认命名、固定类型、自定义后缀、图片限制及旧输入模式")
    }
}
