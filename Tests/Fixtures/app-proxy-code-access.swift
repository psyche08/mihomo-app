import Foundation
import Darwin

// Development-only two-process test. Reads one caller-created fixture, never user app data.
let args = CommandLine.arguments
func emit(_ value: [String: Bool]) {
    print(String(data: try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), encoding: .utf8)!)
}
do {
    if args[1] == "issue" {
        let path = args[2]
        let identity = try AppProxyCodeIdentity.inspect(path: path, category: "claude")
        let grant = try URL(fileURLWithPath: path).bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        let snapshot = AppProxyIdentitySnapshot(ownerUID: getuid(), records: [identity], grants: [grant])
        FileHandle.standardOutput.write(try snapshot.encoded())
    } else {
        if args[1] == "rootReceive" { guard getuid() == 0 else { exit(1) } }
        let before = open(args[2], O_RDONLY | O_NOFOLLOW)
        if before >= 0 { close(before) }
        let snapshot = try AppProxyIdentitySnapshot.decode(FileHandle.standardInput.readDataToEndOfFile())
        if args[1] == "invalidIdentity" || args[1] == "replaced" {
            do { _ = try AppProxyAccessLease(snapshot); exit(1) }
            catch let failure as AppProxyIdentityFailure {
                let allowed: [AppProxyIdentityFailure] = args[1] == "invalidIdentity" ? [.signature] : [.signature, .changedFile, .staleAuthorization]
                guard allowed.contains(failure) else { throw failure }
                emit(["invalidIdentityRejected": true]); exit(0)
            }
        }
        if args[1] == "deny" {
            do { _ = try AppProxyAccessLease(snapshot); emit(["writableGrantRejected": false]); exit(1) }
            catch AppProxyIdentityFailure.permission { emit(["writableGrantRejected": true]); exit(0) }
        }
        let lease = try AppProxyAccessLease(snapshot)
        try lease.revalidate()
        let writeFD = open(args[2], O_WRONLY | O_NOFOLLOW)
        if writeFD >= 0 { close(writeFD) }
        let sibling = open(args[3], O_RDONLY | O_NOFOLLOW)
        if sibling >= 0 { close(sibling) }
        emit(["initiallyDenied": before < 0, "readValidated": true, "writeDenied": writeFD < 0, "siblingDenied": sibling < 0, "rootReceiver": getuid() == 0])
        guard before < 0, writeFD < 0, sibling < 0 else { exit(1) }
        withExtendedLifetime(lease) {}
    }
} catch {
    // No path, bookmark bytes, private certificate or arbitrary localized error is printed.
    FileHandle.standardError.write(Data("code_access_test_failed=\((error as? AppProxyIdentityFailure)?.rawValue ?? "foundation")\n".utf8))
    exit(1)
}
