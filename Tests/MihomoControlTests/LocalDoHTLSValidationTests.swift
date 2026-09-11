import Foundation
import MihomoControl
import XCTest

final class LocalDoHTLSValidationTests: XCTestCase {
    func testProvidingValidSelfSignedCertificateDoesNotGrantSystemTrust() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mihomobox-tls-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let cert = directory.appendingPathComponent("cert.pem").path
        let der = directory.appendingPathComponent("cert.der").path
        func run(_ executable: String, _ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        try run("/usr/bin/openssl", [
            "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes",
            "-days", "1", "-subj", "/CN=MihomoBox Test \(UUID().uuidString)",
            "-addext", "subjectAltName=IP:127.0.0.1",
            "-addext", "basicConstraints=critical,CA:TRUE",
            "-addext", "keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign",
            "-addext", "extendedKeyUsage=serverAuth",
            "-keyout", directory.appendingPathComponent("key.pem").path, "-out", cert,
        ])
        try run("/usr/bin/openssl", ["x509", "-in", cert, "-outform", "DER", "-out", der])
        // Explicit-anchor validation establishes this is a valid SSL identity.
        // Neither this command nor the production check modifies trust stores.
        try run("/usr/bin/security", ["verify-cert", "-c", cert, "-r", cert,
                                      "-p", "ssl", "-s", "127.0.0.1"])
        XCTAssertFalse(LocalDoHTLSValidation.systemTrusts(
            serverPEM: try Data(contentsOf: URL(fileURLWithPath: cert)),
            rootDER: try Data(contentsOf: URL(fileURLWithPath: der))
        ))
    }
}
