import Foundation
import XCTest

/// A throwaway `UserDefaults` suite for one test, stored OUTSIDE
/// `~/Library/Preferences`.
///
/// Why not `UserDefaults(suiteName: "pl.falami.studio.QuickMD.tests.<uuid>")`:
/// that domain lives at `~/Library/Preferences/<suite>.plist`, and
/// `removePersistentDomain` only empties it — cfprefsd writes the (empty)
/// plist seconds later (measured ~20 s after the test process ended), so the
/// file is left behind on every run (324 of them piled up by 2026-11-04).
/// Deleting the file in teardown loses that race as well.
///
/// The suite name here is an ABSOLUTE PATH inside a per-instance temporary
/// directory: CFPreferences then keeps the domain at `<path>.plist`, so even
/// a late cfprefsd write lands in the temporary directory, which `remove()`
/// deletes together with the plist.
final class TemporaryDefaults {
    /// The suite name (an absolute path) — what `persistentDomain(forName:)`
    /// and `removePersistentDomain(forName:)` take.
    let suiteName: String
    let defaults: UserDefaults
    /// The directory that holds the suite's plist.
    let directory: URL

    /// Where CFPreferences stores this suite.
    var plistURL: URL { URL(fileURLWithPath: suiteName + ".plist") }

    init(_ label: String = "tests") throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickMD-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = directory.appendingPathComponent("defaults").path
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw CocoaError(.featureUnsupported)
        }
        self.defaults = defaults
    }

    /// Empties the domain and deletes its plist with the directory. Safe to
    /// call more than once.
    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}

final class TemporaryDefaultsTests: XCTestCase {
    /// The plist is written where the helper says — inside its own temporary
    /// directory — and nothing of it survives `remove()`. With a plain suite
    /// name (the old tests) the flushed plist sits in ~/Library/Preferences
    /// instead and this fails.
    func testPlistStaysInItsTemporaryDirectory() throws {
        let suite = try TemporaryDefaults("Probe")
        defer { suite.remove() }
        suite.defaults.set(42, forKey: "probe")
        XCTAssertTrue(CFPreferencesAppSynchronize(suite.suiteName as CFString))

        XCTAssertTrue(suite.plistURL.path.hasPrefix(suite.directory.path + "/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: suite.plistURL.path),
                      "the domain is stored at <suite path>.plist")
        let library = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences")
            .appendingPathComponent((suite.suiteName as NSString).lastPathComponent + ".plist")
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))

        suite.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: suite.directory.path))
    }
}
