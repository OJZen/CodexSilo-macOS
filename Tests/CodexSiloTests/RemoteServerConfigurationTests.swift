import XCTest
@testable import CodexSilo

final class RemoteServerConfigurationTests: XCTestCase {
    func testMakeDraftUsesSharedDefaults() {
        let draft = RemoteServerConfiguration.makeDraft(id: "server-1")

        XCTAssertEqual(draft.id, "server-1")
        XCTAssertEqual(draft.label, RemoteServerConfiguration.defaultLabel)
        XCTAssertEqual(draft.sshPort, RemoteServerConfiguration.defaultSSHPort)
        XCTAssertEqual(draft.sshUser, RemoteServerConfiguration.defaultSSHUser)
        XCTAssertEqual(draft.authMode, RemoteServerConfiguration.defaultAuthMode)
        XCTAssertEqual(draft.remoteDir, RemoteServerConfiguration.defaultRemoteDir)
        XCTAssertEqual(draft.listenPort, RemoteServerConfiguration.defaultProxyPort)
    }

    func testNormalizeTrimsFieldsAndBackfillsID() {
        let normalized = RemoteServerConfiguration.normalize(
            RemoteServerConfig(
                id: "   ",
                label: "  Tokyo  ",
                host: " 1.2.3.4 ",
                sshPort: 22,
                sshUser: " root ",
                authMode: " keyPath ",
                identityFile: " ~/.ssh/id_ed25519 ",
                privateKey: "  ",
                password: "\nsecret\n",
                remoteDir: " /opt/codex-tools ",
                listenPort: 8787
            ),
            makeID: { "generated-id" }
        )

        XCTAssertEqual(normalized.id, "generated-id")
        XCTAssertEqual(normalized.label, "Tokyo")
        XCTAssertEqual(normalized.host, "1.2.3.4")
        XCTAssertEqual(normalized.sshUser, "root")
        XCTAssertEqual(normalized.authMode, "keyPath")
        XCTAssertEqual(normalized.identityFile, "~/.ssh/id_ed25519")
        XCTAssertNil(normalized.privateKey)
        XCTAssertEqual(normalized.password, "secret")
        XCTAssertEqual(normalized.remoteDir, "/opt/codex-tools")
    }

    func testUpsertReplacesExistingServerByID() {
        let existing = [
            RemoteServerConfig(
                id: "server-1",
                label: "Old",
                host: "1.1.1.1",
                sshPort: 22,
                sshUser: "root",
                authMode: "keyPath",
                identityFile: nil,
                privateKey: nil,
                password: nil,
                remoteDir: "/opt/codex-tools",
                listenPort: 8787
            )
        ]

        let merged = RemoteServerConfiguration.upsert(
            RemoteServerConfig(
                id: "server-1",
                label: " New ",
                host: " 2.2.2.2 ",
                sshPort: 2200,
                sshUser: " admin ",
                authMode: " password ",
                identityFile: nil,
                privateKey: nil,
                password: " pass ",
                remoteDir: " /srv/codex ",
                listenPort: 9797
            ),
            into: existing
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].label, "New")
        XCTAssertEqual(merged[0].host, "2.2.2.2")
        XCTAssertEqual(merged[0].sshUser, "admin")
        XCTAssertEqual(merged[0].authMode, "password")
        XCTAssertEqual(merged[0].password, "pass")
        XCTAssertEqual(merged[0].remoteDir, "/srv/codex")
        XCTAssertEqual(merged[0].listenPort, 9797)
    }
}
