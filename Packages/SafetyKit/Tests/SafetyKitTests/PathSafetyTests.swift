import Foundation
import Testing
@testable import SafetyKit

@Suite("Path safety")
struct PathSafetyTests {
    static let home = "/Users/example"

    @Test("Refuses paths that are too shallow", arguments: [
        "/Users", "/Users/example", "/Library", "/",
    ])
    func refusesShallowPaths(_ path: String) {
        #expect(throws: PathSafetyError.self) {
            try PathSafety.validateForRemoval(path, home: Self.home)
        }
    }

    @Test("Refuses protected system locations", arguments: [
        "/System/Library/Caches/x", "/usr/local/lib/thing", "/private/var/db/x",
        "/Applications/Safari.app", "/Volumes/External/stuff",
    ])
    func refusesProtectedLocations(_ path: String) {
        #expect(throws: PathSafetyError.self) {
            try PathSafety.validateForRemoval(path, home: Self.home)
        }
    }

    @Test("Refuses traversal and relative paths")
    func refusesTraversal() {
        #expect(throws: PathSafetyError.containsTraversal("/Users/example/../../etc/passwd")) {
            try PathSafety.validateForRemoval(
                "/Users/example/../../etc/passwd", home: Self.home
            )
        }
        #expect(throws: PathSafetyError.notAbsolute("relative/path")) {
            try PathSafety.validateForRemoval("relative/path", home: Self.home)
        }
    }

    @Test("Refuses the home directory itself even with a trailing slash")
    func refusesHome() {
        #expect(throws: PathSafetyError.self) {
            try PathSafety.validateForRemoval("/Users/example/", home: Self.home)
        }
    }

    @Test("Accepts a real cache directory")
    func acceptsRealCachePath() throws {
        let home = URL.temporaryDirectory.appending(path: "tortu-safe-\(UUID().uuidString)")
        let cache = home.appending(path: "Library/Caches/example")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        try PathSafety.validateForRemoval(
            cache.path(percentEncoded: false),
            home: home.path(percentEncoded: false)
        )
    }

    @Test("Refuses a path that no longer exists")
    func refusesMissingPath() {
        #expect(throws: PathSafetyError.self) {
            try PathSafety.validateForRemoval(
                "/Users/example/Library/Caches/\(UUID().uuidString)", home: Self.home
            )
        }
    }
}

@Suite("Per-user temporary directories")
struct DarwinUserCacheTests {
    /// `/var` is protected, but the per-user cache area underneath it is a
    /// normal cleanup target and must stay reachable.
    @Test("Accepts a path under /var/folders")
    func acceptsDarwinUserCache() throws {
        let root = URL.temporaryDirectory.appending(path: "tortu-var-\(UUID().uuidString)")
        let cache = root.appending(path: "Caches/example")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let path = cache.path(percentEncoded: false)
        try #require(path.hasPrefix("/var/folders") || path.hasPrefix("/private/var/folders"))
        try PathSafety.validateForRemoval(path, home: "/Users/example")
    }

    @Test("Still refuses the rest of /var", arguments: [
        "/var/db/something/deep", "/private/var/log/system/old",
    ])
    func refusesOtherVarPaths(_ path: String) {
        #expect(throws: PathSafetyError.protectedLocation(path)) {
            try PathSafety.validateForRemoval(path, home: "/Users/example")
        }
    }
}

@Suite("Root allowances")
struct RootAllowanceTests {
    @Test("Anything outside the allow list is refused", arguments: [
        "/Users/someone/Library/Caches/thing",
        "/Library/Developer/Xcode/something",
        "/System/Library/Caches/thing",
        "/Library/Preferences/something/deep",
        "/etc/passwd",
    ])
    func refusesOutsideAllowList(_ path: String) {
        #expect(throws: PathSafetyError.self) {
            try PathSafety.validateForRemovalWithRootAllowances(path)
        }
    }

    @Test("The allow list is narrow on purpose")
    func allowListStaysNarrow() {
        // A long allow list is the failure mode this design exists to avoid.
        #expect(PathSafety.rootAllowedPrefixes.count <= 3)
        #expect(PathSafety.rootAllowedPrefixes.allSatisfy { $0.hasPrefix("/Library/Developer") })
    }

    @Test("Traversal is refused even inside an allowed prefix")
    func refusesTraversalInsideAllowance() {
        let path = "/Library/Developer/CoreSimulator/Caches/../../../../etc"
        #expect(throws: PathSafetyError.containsTraversal(path)) {
            try PathSafety.validateForRemovalWithRootAllowances(path)
        }
    }

    @Test("A path inside an allowed prefix that does not exist is refused")
    func refusesMissingInsideAllowance() {
        #expect(throws: PathSafetyError.self) {
            try PathSafety.validateForRemovalWithRootAllowances(
                "/Library/Developer/CoreSimulator/Caches/dyld/\(UUID().uuidString)"
            )
        }
    }

    @Test("A real path inside an allowed prefix passes")
    func acceptsRealAllowedPath() throws {
        let dyld = "/Library/Developer/CoreSimulator/Caches/dyld"
        try #require(FileManager.default.fileExists(atPath: dyld))
        let entries = try FileManager.default.contentsOfDirectory(atPath: dyld)
        let first = try #require(entries.first)
        try PathSafety.validateForRemovalWithRootAllowances("\(dyld)/\(first)")
    }
}
