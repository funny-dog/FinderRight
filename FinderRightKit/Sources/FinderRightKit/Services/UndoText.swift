import Foundation

/// 撤销相关的菜单标题与提示文案。中文即本地化 key；localize 由调用方传入
/// （主 App 传 NSLocalizedString，扩展传它按界面语言取词的 L）。
public enum UndoText {

    /// 操作本身的描述，如「移动到“Projects”（3 项）」
    public static func actionDescription(kind: UndoRecord.Kind, count: Int, name: String,
                                         localize: (String) -> String) -> String {
        switch kind {
        case .move:       return String(format: localize("移动到“%@”（%d 项）"), name, count)
        case .copy:       return String(format: localize("复制到“%@”（%d 项）"), name, count)
        case .paste:      return String(format: localize("粘贴到“%@”（%d 项）"), name, count)
        case .cut:        return String(format: localize("剪切（%d 项）"), count)
        case .createFile: return String(format: localize("新建“%@”"), name)
        case .compress:   return String(format: localize("压缩“%@”"), name)
        case .decompress: return String(format: localize("解压“%@”"), name)
        case .symlink:    return String(format: localize("创建符号链接（%d 项）"), count)
        }
    }

    public static func menuTitle(for state: UndoMenuState, localize: (String) -> String) -> String {
        String(format: localize("撤销%@"),
               actionDescription(kind: state.kind, count: state.count, name: state.name, localize: localize))
    }

    /// 撤销后的提示：全部成功、部分跳过、一项未撤销三种。多项跳过时只写第一项原因 +「等 N 项」
    public static func feedback(for record: UndoRecord, outcome: UndoOutcome, localize: (String) -> String) -> String {
        let action = actionDescription(kind: record.kind, count: record.count, name: record.name, localize: localize)
        guard let first = outcome.skipped.first else {
            return String(format: localize("已撤销：%@"), action)
        }
        var reason = skipReason(first, localize: localize)
        if outcome.skipped.count > 1 {
            reason += String(format: localize("等 %d 项"), outcome.skipped.count - 1)
        }
        if outcome.undone.isEmpty {
            return String(format: localize("无法撤销：%@"), reason)
        }
        return String(format: localize("已撤销 %d 项，跳过 %d 项：%@"), outcome.undone.count, outcome.skipped.count, reason)
    }

    public static func skipReason(_ skip: UndoOutcome.Skip, localize: (String) -> String) -> String {
        switch skip.reason {
        case .missing:               return String(format: localize("“%@”已不存在"), skip.name)
        case .modified:              return String(format: localize("“%@”在操作后被修改"), skip.name)
        case .originalOccupied:      return String(format: localize("“%@”原位置已有同名项目"), skip.name)
        case .originalFolderMissing: return String(format: localize("“%@”的原文件夹已不存在"), skip.name)
        case .failed(let message):   return String(format: localize("“%@”：%@"), skip.name, message)
        }
    }
}
