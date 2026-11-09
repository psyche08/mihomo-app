import Foundation
import Darwin
import Security

// Development-only two-process test. Reads caller-created fixtures, never user app data.
let args = CommandLine.arguments
func emit(_ value: [String: Bool]) {
    print(String(data: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)!)
}
func failure(_ body: () throws -> Void) -> AppProxyIdentityFailure? {
    do { try body(); return nil } catch { return error as? AppProxyIdentityFailure ?? .malformed }
}
func policy(folder: String, readOnly: Bool) throws -> Data {
    // The broker's check: a grant never gives write access to code.
    if readOnly { try AppProxyCode.requireReadOnlyFolder(folder) }
    let grant = try URL(fileURLWithPath: folder, isDirectory: true)
        .bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    let route = AppProxyPolicy.Route(category: "claude", teams: ["Q6L2SF6YDW"], identifiers: ["dev.linsheng.mihomo.fixture"])
    return try AppProxyPolicy(ownerUID: getuid(), routes: [route], folders: [folder], grants: [grant],
                              codeStamp: String(repeating: "0", count: 64)).encoded()
}
do {
    switch args[1] {
    case "issue": FileHandle.standardOutput.write(try policy(folder: args[2], readOnly: true))
    // A host outside the read-only broker could mint a writable grant; the provider must refuse it.
    case "issueWritable": FileHandle.standardOutput.write(try policy(folder: args[2], readOnly: false))
    case "refuseLink":
        guard failure({ try AppProxyCode.requireReadOnlyFolder(args[2]) }) == .escapedPath else { exit(1) }
        emit(["linkRefused": true])
    default:
        if args[1] == "rootReceive" { guard getuid() == 0 else { exit(1) } }
        let folder = args[2], code = args[3], sibling = args[4]
        let before = open(code, O_RDONLY | O_NOFOLLOW)
        if before >= 0 { close(before) }
        let policy = try AppProxyPolicy.decode(FileHandle.standardInput.readDataToEndOfFile())
        precondition(policy.folders == [folder])
        if args[1] == "deny" || args[1] == "stale" {
            let expected: AppProxyIdentityFailure = args[1] == "deny" ? .permission : .staleAuthorization
            let result = failure { _ = try AppProxyFolderAccess(policy) }
            emit([args[1] == "deny" ? "writableGrantRejected" : "staleGrantRejected": result == expected])
            exit(result == expected ? 0 : 1)
        }
        let access = try AppProxyFolderAccess(policy)
        // What NetworkExtension does inside the provider: open and validate the code.
        var staticCode: SecStaticCode?
        let validated = SecStaticCodeCreateWithPath(URL(fileURLWithPath: code) as CFURL, [], &staticCode) == errSecSuccess
            && staticCode.map { SecStaticCodeCheckValidity($0, [], nil) == errSecSuccess } == true
        let writeFD = open(code, O_WRONLY | O_NOFOLLOW)
        if writeFD >= 0 { close(writeFD) }
        let created = open(folder + "/created", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        if created >= 0 { close(created); unlink(folder + "/created") }
        let siblingFD = open(sibling, O_RDONLY | O_NOFOLLOW)
        if siblingFD >= 0 { close(siblingFD) }
        emit(["initiallyDenied": before < 0, "codeValidated": validated, "writeDenied": writeFD < 0, "createDenied": created < 0,
              "siblingDenied": siblingFD < 0, "rootReceiver": getuid() == 0])
        guard before < 0, validated, writeFD < 0, created < 0, siblingFD < 0 else { exit(1) }
        withExtendedLifetime(access) {}
    }
} catch {
    // No path, bookmark bytes, private certificate or arbitrary localized error is printed.
    FileHandle.standardError.write(Data("code_access_test_failed=\((error as? AppProxyIdentityFailure)?.rawValue ?? "foundation")\n".utf8))
    exit(1)
}
