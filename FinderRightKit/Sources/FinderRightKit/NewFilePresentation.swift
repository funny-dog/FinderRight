import Foundation

/// 桌面新建后无需再打开目录窗口，其他目录仍定位新文件。
public enum NewFilePresentation {
    public static func shouldReveal(in directory: URL,
                                    desktopDirectory: URL? = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first) -> Bool {
        guard let desktopDirectory else { return true }
        return directory.resolvingSymlinksInPath().path != desktopDirectory.resolvingSymlinksInPath().path
    }
}
