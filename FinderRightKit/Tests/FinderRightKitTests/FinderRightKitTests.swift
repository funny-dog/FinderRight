import Foundation
import AppKit
import FinderRightKit
import Compression
import CryptoKit
import ImageIO

@main
struct FinderRightKitTestsRunner {
    static func main() {
        print("=========================================")
        print("    FinderRightKit 单元测试套件运行中")
        print("=========================================\n")
        CoreTests.run()
        ArchiveTests.run()
        ExtractTests.run()
        MenuTests.run()
        ShortcutTests.run()
        MiscTests.run()
        BatchRenameTests.run()
        DeveloperTests.run()
        RegressionTests.run()

        print("\n-----------------------------------------")
        print("测试结果: 总数 \(totalTests)，通过 \(passedTests)，失败 \(failedTests)")
        print("-----------------------------------------")

        if !testFilter.isEmpty && totalTests == 0 {
            print("⚠️ 过滤词 '\(testFilter)' 未匹配到任何测试用例")
            exit(1)
        }

        if failedTests > 0 {
            exit(1)
        }
    }
}
