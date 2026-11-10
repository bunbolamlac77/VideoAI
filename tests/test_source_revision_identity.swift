import Foundation
import CryptoKit

@main
struct TestSourceRevisionIdentity {
    static func main() throws {
        print("=== RUNNING SOURCE REVISION IDENTITY TESTS ===")

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Test 1: Regular file SHA-256 fingerprinting
        let testFile = tempDir.appendingPathComponent("test_clip.mp4")
        let testData = "aivideo_test_frame_stream_0123456789".data(using: .utf8)!
        try testData.write(to: testFile)

        let fp = try SourceRevisionIdentity.fingerprint(filePath: testFile.path)
        let expectedSHA = SHA256.hash(data: testData).map { String(format: "%02x", $0) }.joined()

        assert(fp.sha256 == expectedSHA, "SHA-256 mismatch! Got \(fp.sha256), expected \(expectedSHA)")
        assert(fp.canonicalPath == testFile.resolvingSymlinksInPath().path, "Canonical path mismatch")
        print("  ✅ PASS: S10.SHA.1: Regular file SHA-256 fingerprint verified (\(fp.sha256.prefix(12))...)")

        // Test 2: Directory or non-regular file throws notRegularFile
        do {
            _ = try SourceRevisionIdentity.fingerprint(filePath: tempDir.path)
            fatalError("Should have failed for directory!")
        } catch let err as SourceRevisionIdentityError {
            assert(err == .notRegularFile, "Expected notRegularFile, got \(err)")
            print("  ✅ PASS: S10.SHA.2: Directory rejected with notRegularFile error")
        }

        print("ALL SOURCE REVISION IDENTITY TESTS PASSED!")
    }
}
