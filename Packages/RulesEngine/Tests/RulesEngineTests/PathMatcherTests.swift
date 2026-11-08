import Foundation
import Testing
@testable import RulesEngine

@Suite("Path matching")
struct PathMatcherTests {
    static func makeTree() throws -> URL {
        let manager = FileManager.default
        let home = URL.temporaryDirectory.appending(path: "tortu-home-\(UUID().uuidString)")
        let paths = [
            "Library/Developer/Xcode/DerivedData/ProjectA-abc",
            "Library/Developer/Xcode/DerivedData/ProjectB-def",
            "Library/Caches/com.example.app",
            "Projects/alpha/.dart_tool/flutter_build/hash1",
            "Projects/alpha/.dart_tool/flutter_build/hash2",
            "Projects/beta/nested/deep/.dart_tool/flutter_build/hash3",
            "Projects/alpha/node_modules/.dart_tool/flutter_build/should-be-pruned",
        ]
        for path in paths {
            try manager.createDirectory(
                at: home.appending(path: path), withIntermediateDirectories: true
            )
        }
        try Data("x".utf8).write(to: home.appending(path: "Library/Caches/loose.txt"))
        return home
    }

    static func matcher(home: URL) -> PathMatcher {
        PathMatcher(home: home.path(percentEncoded: false))
    }

    @Test("A literal path with one wildcard lists that directory")
    func literalThenWildcard() throws {
        let home = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: home) }

        let found = Self.matcher(home: home)
            .matches(pattern: "~/Library/Developer/Xcode/DerivedData/*")
        #expect(found.count == 2)
        #expect(found.allSatisfy { $0.contains("DerivedData/Project") })
    }

    @Test("A recursive pattern finds the same directory at several depths")
    func recursivePattern() throws {
        let home = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: home) }

        let found = Self.matcher(home: home)
            .matches(pattern: "~/**/.dart_tool/flutter_build/*")
        let names = found.map { URL(filePath: $0).lastPathComponent }.sorted()
        #expect(names == ["hash1", "hash2", "hash3"])
    }

    @Test("Recursion does not descend into pruned directories")
    func prunesHeavyDirectories() throws {
        let home = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: home) }

        let found = Self.matcher(home: home)
            .matches(pattern: "~/**/.dart_tool/flutter_build/*")
        #expect(!found.contains { $0.contains("node_modules") })
    }

    @Test("Recursion respects its depth limit")
    func respectsDepthLimit() throws {
        let home = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: home) }

        let shallow = PathMatcher(
            options: .init(maxRecursiveDepth: 1),
            home: home.path(percentEncoded: false)
        )
        let found = shallow.matches(pattern: "~/**/.dart_tool/flutter_build/*")
        // Only alpha sits one level under Projects; beta's copy is deeper.
        #expect(!found.contains { $0.contains("beta") })
    }

    @Test("A pattern that matches nothing returns nothing")
    func noMatches() throws {
        let home = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: home) }

        #expect(Self.matcher(home: home).matches(pattern: "~/Nowhere/*").isEmpty)
        #expect(Self.matcher(home: home).matches(pattern: "relative/path").isEmpty)
    }

    @Test("A literal pattern matches an exact directory")
    func literalOnly() throws {
        let home = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: home) }

        let found = Self.matcher(home: home).matches(pattern: "~/Library/Caches")
        #expect(found.count == 1)
        #expect(found[0].hasSuffix("/Library/Caches"))
    }

    @Test("Partial wildcards inside a segment work")
    func partialWildcard() throws {
        let home = try Self.makeTree()
        defer { try? FileManager.default.removeItem(at: home) }

        let found = Self.matcher(home: home)
            .matches(pattern: "~/Library/Developer/Xcode/DerivedData/ProjectA-*")
        #expect(found.count == 1)
    }
}
