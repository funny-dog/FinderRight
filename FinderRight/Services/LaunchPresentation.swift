import AppKit

enum LaunchPresentation {
    static let showSettingsArgument = "--show-settings"

    static func shouldShowSettings(isDefaultLaunch: Bool,
                                   event: NSAppleEventDescriptor?,
                                   receivedURL: Bool,
                                   arguments: [String]) -> Bool {
        if arguments.contains(showSettingsArgument) { return true }
        guard isDefaultLaunch, !receivedURL else { return false }
        guard let event else { return true }
        guard event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEOpenApplication) else { return false }
        // 登录项和 Services 也会收到 open-application，不能只按事件类型弹窗。
        let context = event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
        return context != keyAELaunchedAsLogInItem && context != keyAELaunchedAsServiceItem
    }
}
