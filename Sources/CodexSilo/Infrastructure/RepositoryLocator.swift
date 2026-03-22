import Foundation

enum RepositoryLocator {
    static let proxydManifestRelativePath = "src-tauri/proxyd/Cargo.toml"
    static let proxydBundledManifestRelativePath = "proxyd-src/proxyd/Cargo.toml"
    static let proxydBinaryName = "codex-tools-proxyd"

    static func findRepoRoot(startingAt start: URL = URL(fileURLWithPath: #filePath)) -> URL? {
        var current = start
        if !current.hasDirectoryPath {
            current.deleteLastPathComponent()
        }

        for _ in 0..<12 {
            let marker = current.appendingPathComponent(proxydManifestRelativePath, isDirectory: false)
            if FileManager.default.fileExists(atPath: marker.path) {
                return current
            }
            let next = current.deletingLastPathComponent()
            if next.path == current.path {
                break
            }
            current = next
        }

        var cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        for _ in 0..<8 {
            let marker = cwd.appendingPathComponent(proxydManifestRelativePath, isDirectory: false)
            if FileManager.default.fileExists(atPath: marker.path) {
                return cwd
            }
            let next = cwd.deletingLastPathComponent()
            if next.path == cwd.path {
                break
            }
            cwd = next
        }

        return nil
    }
}
