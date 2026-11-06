import Foundation
import AppKit

/// 全局快捷键触发器
public enum GlobalHotkeyTrigger {
    
    /// Ctrl+Space 监听器
    public static var fastSearchMonitor: Any? = {
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.contains(.control),
                  (event.charactersIgnoringModifiers?.lowercased()) == " " else { return }
            
            // 在这里调用快速搜索显示
            // FinderRight/Views/FastSearchController.shared.show()
            
            // 阻止冒泡
        }
    }
}
