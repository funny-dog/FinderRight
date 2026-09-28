import SwiftUI

/// 解决命令行工具 (CommandLineTools) 下缺少 SwiftUIMacros 宏插件的问题
/// 用原生属性包装器等效替代 @State，在 macOS 13+ / 14+ 均可无损编译运行
@propertyWrapper
public struct FRState<Value>: DynamicProperty {
    private var state: SwiftUI.State<Value>

    public init(wrappedValue: Value) {
        self.state = SwiftUI.State(wrappedValue: wrappedValue)
    }

    public init(initialValue: Value) {
        self.state = SwiftUI.State(initialValue: initialValue)
    }

    public var wrappedValue: Value {
        get { state.wrappedValue }
        nonmutating set { state.wrappedValue = newValue }
    }

    public var projectedValue: Binding<Value> {
        state.projectedValue
    }
}
