import Foundation

enum RemoteServerConfiguration {
    static let defaultProxyPort = 8787
    static let defaultSSHPort = 22
    static let defaultLabel = "new-server"
    static let defaultSSHUser = "root"
    static let defaultAuthMode = "keyPath"
    static let defaultRemoteDir = "/opt/codex-tools"

    static func makeDraft(id: String = UUID().uuidString) -> RemoteServerConfig {
        RemoteServerConfig(
            id: id,
            label: defaultLabel,
            host: "",
            sshPort: defaultSSHPort,
            sshUser: defaultSSHUser,
            authMode: defaultAuthMode,
            identityFile: nil,
            privateKey: nil,
            password: nil,
            remoteDir: defaultRemoteDir,
            listenPort: defaultProxyPort
        )
    }

    static func normalize(
        _ server: RemoteServerConfig,
        makeID: () -> String = { UUID().uuidString }
    ) -> RemoteServerConfig {
        var value = server
        value.id = trimmed(value.id) ?? makeID()
        value.label = trimmed(value.label) ?? ""
        value.host = trimmed(value.host) ?? ""
        value.sshUser = trimmed(value.sshUser) ?? ""
        value.remoteDir = trimmed(value.remoteDir) ?? ""
        value.authMode = trimmed(value.authMode) ?? defaultAuthMode
        value.identityFile = trimmed(value.identityFile)
        value.privateKey = trimmed(value.privateKey)
        value.password = trimmed(value.password)
        return value
    }

    static func upsert(
        _ server: RemoteServerConfig,
        into servers: [RemoteServerConfig],
        makeID: () -> String = { UUID().uuidString }
    ) -> [RemoteServerConfig] {
        let normalized = normalize(server, makeID: makeID)
        var merged = servers
        if let index = merged.firstIndex(where: { $0.id == normalized.id }) {
            merged[index] = normalized
        } else {
            merged.append(normalized)
        }
        return merged
    }

    static func statusLabel(_ status: RemoteProxyStatus?) -> String {
        guard let status else { return "Unknown" }
        return status.running ? L10n.tr("proxy.status.running") : L10n.tr("proxy.status.stopped")
    }

    static func boolText(_ value: Bool?) -> String {
        guard let value else { return "Unknown" }
        return value ? "Yes" : "No"
    }

    static func isPlaceholderDraft(_ server: RemoteServerConfig) -> Bool {
        let trimmedLabel = server.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedLabel.isEmpty || trimmedLabel == defaultLabel
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
