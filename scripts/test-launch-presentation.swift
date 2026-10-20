import AppKit

@main
struct LaunchPresentationChecks {
    static func main() {
        func launchEvent(_ context: AEKeyword? = nil) -> NSAppleEventDescriptor {
            let event = NSAppleEventDescriptor(
                eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication),
                targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                transactionID: AETransactionID(kAnyTransactionID))
            if let context {
                event.setParam(NSAppleEventDescriptor(enumCode: context), forKeyword: keyAEPropData)
            }
            return event
        }

        func check(_ name: String, expected: Bool, isDefaultLaunch: Bool = true,
                   event: NSAppleEventDescriptor? = nil, receivedURL: Bool = false,
                   arguments: [String] = []) {
            precondition(LaunchPresentation.shouldShowSettings(
                isDefaultLaunch: isDefaultLaunch, event: event,
                receivedURL: receivedURL, arguments: arguments) == expected, name)
            print("✓ \(name)")
        }

        check("主动打开显示设置", expected: true, event: launchEvent())
        check("直接启动可执行文件显示设置", expected: true)
        check("登录自启保持后台", expected: false, event: launchEvent(keyAELaunchedAsLogInItem))
        check("Services 冷启动保持后台", expected: false, event: launchEvent(keyAELaunchedAsServiceItem))
        check("非默认启动不弹设置", expected: false, isDefaultLaunch: false)
        check("已收到 URL 时不额外弹设置", expected: false, event: launchEvent(), receivedURL: true)
        let urlEvent = NSAppleEventDescriptor(
            eventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL),
            targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID))
        check("URL 冷启动不额外弹设置", expected: false, event: urlEvent)
        check("语言切换与更新重启显式显示设置", expected: true, isDefaultLaunch: false,
              arguments: [LaunchPresentation.showSettingsArgument])
        check("自动更新重启保持后台", expected: false,
              arguments: [LaunchPresentation.backgroundArgument])
        check("无关参数不改变后台启动", expected: false, isDefaultLaunch: false,
              arguments: ["--other"])
    }
}
