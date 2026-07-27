import Foundation

/// 在「应用程序」目录里维护一个指向本 .app 的 Finder 别名，让聚焦搜得到。
///
/// ★ 为什么是别名（bookmark）而不是软链接 ★
///   Homebrew formula 把 .app 装在 Cellar 里，聚焦不索引那里；指向 App 的
///   **软链接**聚焦同样不认。Finder 别名是真正的书签文件：聚焦按文件名索引它，
///   回车即启动目标。用 URL 的 bookmark API（.suitableForBookmarkFile）生成，
///   不需要 Finder 帮忙、不触发任何权限弹窗。
///
/// ★ 为什么由 App 自己维护 ★
///   brew 没有 root、formula 也不该在构建沙箱里往用户目录伸手。App 每次启动
///   顺手校一遍：别名缺了就补、目标漂移（brew upgrade 换了 Cellar 版本路径）
///   就重写。formula 的 post_install 另以 `--install-finder-alias` 调一次本
///   App（建完即退），做到「装完就能搜到」，不用等首次启动。
enum FinderAlias {
    /// 别名文件名。不带 .app —— 它是书签文件，不是 bundle；
    /// 聚焦显示的名字就是它。
    private static let aliasName = "TetherKit"

    /// 确保别名存在且指向 bundleURL。返回一句人话结果（--install-finder-alias
    /// 模式会原样打印）。失败不抛错 —— 别名是锦上添花，不该拦住任何流程。
    @discardableResult
    static func ensure(for bundleURL: URL) -> String {
        guard bundleURL.pathExtension == "app" else {
            return "跳过：不是 .app 包（开发构建）"
        }
        let target = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        guard !target.path.hasPrefix("/Applications/") else {
            return "跳过：App 已在 /Applications 里"
        }

        // 先试全局 /Applications（admin 组可写，不需要 root）；
        // 写不进去（受管机器、非管理员账户）退回 ~/Applications —— 聚焦同样索引。
        let candidates = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true),
        ]
        for directory in candidates {
            do {
                if let message = try ensure(in: directory, target: target) {
                    return message
                }
            } catch {
                continue
            }
        }
        return "失败：/Applications 与 ~/Applications 都没能写入别名"
    }

    /// 在指定目录里建立/修复别名。位置被非别名文件占用时返回 nil（换下一个
    /// 候选目录），其余失败抛错。
    private static func ensure(in directory: URL, target: URL) throws -> String? {
        let aliasURL = directory.appendingPathComponent(aliasName)
        let path = aliasURL.path

        if FileManager.default.fileExists(atPath: path) {
            let isAlias = (try? aliasURL.resourceValues(forKeys: [.isAliasFileKey]))?
                .isAliasFile ?? false
            // 不是我们的别名（用户自己拷了个同名文件？）就绝不动它。
            guard isAlias else { return nil }

            if let resolved = try? URL(resolvingAliasFileAt: aliasURL,
                                       options: [.withoutUI, .withoutMounting]),
               resolved.standardizedFileURL.path == target.path {
                return "别名已就绪：\(path)"
            }
            // 目标漂移（升级换了路径）—— 重写。
        }

        let bookmark = try target.bookmarkData(options: .suitableForBookmarkFile,
                                               includingResourceValuesForKeys: nil,
                                               relativeTo: nil)
        try URL.writeBookmarkData(bookmark, to: aliasURL)
        return "已建立别名：\(path) → \(target.path)"
    }
}
