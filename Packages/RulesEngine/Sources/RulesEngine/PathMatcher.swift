import Foundation
import ScanCore

/// Resolves a rule's glob patterns into paths that actually exist.
///
/// Patterns are matched segment by segment rather than by walking everything
/// and filtering. A literal segment is appended directly, so
/// `~/Library/Developer/Xcode/DerivedData/*` costs one directory listing
/// rather than a traversal of the home folder.
public struct PathMatcher: Sendable {
    public struct Options: Sendable {
        /// How deep `**` is allowed to reach. Project trees that hide a build
        /// directory are a few levels down; letting `**` run unbounded would
        /// turn one rule into a full-disk scan.
        public var maxRecursiveDepth: Int
        /// Directory names never descended into while expanding `**`.
        public var prunedDirectoryNames: Set<String>

        public init(
            maxRecursiveDepth: Int = 6,
            prunedDirectoryNames: Set<String> = [
                // Already-matched build output: descending inside one to find
                // another is wasted work, since removing the outer one takes
                // the inner with it.
                "node_modules", ".git", ".build", "Pods", "DerivedData",
                // `**` patterns exist to find project trees. These hold no
                // projects and are enormous; walking them turned a rule that
                // should take under a second into thirteen.
                "Library", "Applications", ".Trash", "Pictures", "Music", "Movies",
            ]
        ) {
            self.maxRecursiveDepth = maxRecursiveDepth
            self.prunedDirectoryNames = prunedDirectoryNames
        }

        public static let `default` = Options()
    }

    private let reader: any DirectoryReading
    private let options: Options
    private let home: String

    public init(
        reader: any DirectoryReading = FastDirectoryReader(),
        options: Options = .default,
        home: String = NSHomeDirectory()
    ) {
        self.reader = reader
        self.options = options
        self.home = home
    }

    public func matches(pattern: String) -> [String] {
        let expanded = pattern.hasPrefix("~/")
            ? home + String(pattern.dropFirst(1))
            : pattern
        guard expanded.hasPrefix("/") else { return [] }

        let segments = expanded.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        var current = ["/"]

        for (index, segment) in segments.enumerated() {
            let isLast = index == segments.count - 1
            switch segment {
            case "**":
                current = current.flatMap { descendants(of: $0, depth: 0) }
            default:
                if segment.containsGlobCharacters {
                    current = current.flatMap { children(of: $0, matching: segment) }
                } else {
                    current = current.compactMap { base in
                        let joined = join(base, segment)
                        return exists(joined) ? joined : nil
                    }
                }
            }
            if current.isEmpty { return [] }
            if isLast { break }
        }
        return current.sorted()
    }

    /// Every directory at or below `path`, the zero-level case included, so
    /// `~/**/build` also matches `~/build`.
    private func descendants(of path: String, depth: Int) -> [String] {
        var found = [path]
        guard depth < options.maxRecursiveDepth else { return found }
        guard let entries = try? reader.entries(at: path) else { return found }
        for entry in entries where entry.kind == .directory {
            guard !options.prunedDirectoryNames.contains(entry.name) else { continue }
            found.append(contentsOf: descendants(of: join(path, entry.name), depth: depth + 1))
        }
        return found
    }

    private func children(of path: String, matching pattern: String) -> [String] {
        guard let entries = try? reader.entries(at: path) else { return [] }
        return entries
            .filter { fnmatch(pattern, $0.name, 0) == 0 }
            .map { join(path, $0.name) }
    }

    private func join(_ base: String, _ component: String) -> String {
        base.hasSuffix("/") ? base + component : base + "/" + component
    }

    private func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }
}

private extension String {
    var containsGlobCharacters: Bool {
        contains("*") || contains("?") || contains("[")
    }
}
