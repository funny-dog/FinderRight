import Foundation
import FinderRightKit

@main
struct ServiceDriftChecks {
    static func main() throws {
        let fileManager = FileManager.default
        let currentDir = URL(fileURLWithPath: fileManager.currentDirectoryPath)

        // 定位工程根目录
        var rootDir = currentDir
        while !fileManager.fileExists(atPath: rootDir.appendingPathComponent("FinderRight/Info.plist").path) {
            let parent = rootDir.deletingLastPathComponent()
            if parent.path == rootDir.path {
                print("✗ 找不到工程根目录 (FinderRight/Info.plist)")
                exit(1)
            }
            rootDir = parent
        }

        let plistURL = rootDir.appendingPathComponent("FinderRight/Info.plist")
        let providerURL = rootDir.appendingPathComponent("FinderRight/Services/ServicesProvider.swift")
        let stringsURL = rootDir.appendingPathComponent("FinderRight/zh-Hans.lproj/ServicesMenu.strings")

        guard let plistData = try? Data(contentsOf: plistURL) else {
            print("✗ 无法读取文件: \(plistURL.path)")
            exit(1)
        }
        guard let providerSource = try? String(contentsOf: providerURL, encoding: .utf8) else {
            print("✗ 无法读取文件: \(providerURL.path)")
            exit(1)
        }
        guard let stringsSource = try? String(contentsOf: stringsURL, encoding: .utf8) else {
            print("✗ 无法读取文件: \(stringsURL.path)")
            exit(1)
        }

        let plistServices = ServiceMenuDriftChecker.parseNSServices(fromPlistData: plistData)
        let stringsKeys = ServiceMenuDriftChecker.parseServicesMenuKeys(fromStringContent: stringsSource)

        let issues = ServiceMenuDriftChecker.verify(
            features: MenuFeatureCatalog.all,
            plistServices: plistServices,
            providerSource: providerSource,
            servicesMenuKeys: stringsKeys
        )

        if !issues.isEmpty {
            print("=========================================")
            print("❌ 服务菜单防漂移检查失败，发现 \(issues.count) 处不一致：")
            print("=========================================")
            for (idx, issue) in issues.enumerated() {
                print("[\(idx + 1)] \(issue)")
            }
            exit(1)
        }

        print("✓ 服务菜单防漂移检查通过：所有声明的服务与 Info.plist、ServicesProvider、ServicesMenu.strings 完全一致")
    }
}
