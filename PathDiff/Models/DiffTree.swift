//
//  DiffTree.swift
//  PathDiff
//

import Foundation

/// Pure helpers for navigating and updating an immutable `[DiffNode]` tree by relative path.
/// Path helpers that tolerate symlinked spellings of the same folder
/// (e.g. `/var/…` and `/private/var/…`).
nonisolated enum PathUtilities {
    /// `path` relative to `root`, or `nil` when it isn't inside it.
    static func relativePath(_ path: String, to root: String) -> String? {
        for candidate in spellings(of: root) {
            let prefix = candidate.hasSuffix("/") ? candidate : candidate + "/"
            if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
            if path == candidate { return "" }
        }
        return nil
    }

    /// The root as given, symlink-resolved, and with or without the `/private` prefix.
    static func spellings(of root: String) -> [String] {
        var result = [root]
        if let resolved = realpath(root, nil) {
            result.append(String(cString: resolved))
            free(resolved)
        }
        for spelling in result {
            if spelling.hasPrefix("/private/") {
                result.append(String(spelling.dropFirst("/private".count)))
            } else {
                result.append("/private" + spelling)
            }
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }
}

nonisolated enum DiffTree {
    static func components(of path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    static func parentPath(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    /// Strict ancestors, shallowest first: `a/b/c` → `["a", "a/b"]`.
    static func ancestorPaths(of path: String) -> [String] {
        var result: [String] = []
        var prefix = ""
        for component in components(of: path).dropLast() {
            prefix = prefix.isEmpty ? component : prefix + "/" + component
            result.append(prefix)
        }
        return result
    }

    static func isSameOrDescendant(_ path: String, of ancestor: String) -> Bool {
        path == ancestor || path.hasPrefix(ancestor + "/")
    }

    static func node(at path: String, in nodes: [DiffNode]) -> DiffNode? {
        var level = nodes
        var found: DiffNode?
        for component in components(of: path) {
            guard let match = level.first(where: { $0.name == component }) else { return nil }
            found = match
            level = match.children ?? []
        }
        return found
    }

    /// Replaces, inserts (sorted) or removes the node at `path`, then recomputes every ancestor.
    /// The parent folder of `path` must already exist in the tree.
    static func replacing(path: String, with newNode: DiffNode?, in nodes: [DiffNode]) -> [DiffNode] {
        let parts = components(of: path)
        guard !parts.isEmpty else { return nodes }
        return replace(parts[...], with: newNode, in: nodes)
    }

    private static func replace(_ parts: ArraySlice<String>, with newNode: DiffNode?, in nodes: [DiffNode]) -> [DiffNode] {
        guard let name = parts.first else { return nodes }
        var nodes = nodes
        let index = nodes.firstIndex { $0.name == name }

        if parts.count == 1 {
            switch (index, newNode) {
            case let (index?, replacement?):
                nodes[index] = replacement
            case let (index?, nil):
                nodes.remove(at: index)
            case let (nil, insertion?):
                let position = nodes.firstIndex { DiffNode.sortPrecedes(insertion, $0) } ?? nodes.endIndex
                nodes.insert(insertion, at: position)
            case (nil, nil):
                break
            }
            return nodes
        }

        guard let index, nodes[index].isDirectory else { return nodes }
        var directory = nodes[index]
        directory.children = replace(parts.dropFirst(), with: newNode, in: directory.children ?? [])
        directory.recomputeAggregates()
        nodes[index] = directory
        return nodes
    }

    /// The path that has to be rescanned so a change at `path` can be merged into the tree:
    /// `path` itself when its parent folder is already known, otherwise the shallowest
    /// ancestor that is missing (or not a folder) in the tree.
    static func refreshTarget(for path: String, in nodes: [DiffNode]) -> String {
        let parts = components(of: path)
        var level = nodes
        var prefix = ""
        for (offset, component) in parts.enumerated() {
            prefix = prefix.isEmpty ? component : prefix + "/" + component
            if offset == parts.count - 1 { return path }
            guard let match = level.first(where: { $0.name == component }),
                  match.isDirectory, !match.hasKindMismatch, match.status != .ignored
            else { return prefix }
            level = match.children ?? []
        }
        return path
    }

    /// Whether `path` is, or lies inside, an ignored node of the tree.
    static func isInsideIgnoredNode(_ path: String, in nodes: [DiffNode]) -> Bool {
        var level = nodes
        for component in components(of: path) {
            guard let match = level.first(where: { $0.name == component }) else { return false }
            if match.status == .ignored { return true }
            level = match.children ?? []
        }
        return false
    }

    /// Number of non-ignored files at or below `node`.
    static func fileCount(in node: DiffNode) -> Int {
        guard node.isDirectory else { return node.status == .ignored ? 0 : 1 }
        var count = 0
        forEachDepthFirst(node.children ?? []) { child in
            if !child.isDirectory && child.status != .ignored { count += 1 }
        }
        return count
    }

    /// Drops every path that is already covered by one of its ancestors in the set.
    /// Linear in the number of paths (looking up each one's ancestors), since bursts of file
    /// system events can bring thousands.
    static func minimalPaths(_ paths: Set<String>) -> [String] {
        paths.sorted().filter { path in !ancestorPaths(of: path).contains(where: paths.contains) }
    }

    static func forEachDepthFirst(_ nodes: [DiffNode], _ body: (DiffNode) -> Void) {
        for node in nodes {
            body(node)
            if let children = node.children { forEachDepthFirst(children, body) }
        }
    }

    static func mirrored(_ nodes: [DiffNode]) -> [DiffNode] {
        nodes.map { $0.mirrored() }
    }

    /// Paths of every folder that has children.
    static func expandableDirectoryPaths(in nodes: [DiffNode], onlyWithDifferences: Bool) -> Set<String> {
        var result = Set<String>()
        forEachDepthFirst(nodes) { node in
            guard node.isDirectory, node.hasChildren else { return }
            if !onlyWithDifferences || node.differenceCount > 0 { result.insert(node.id) }
        }
        return result
    }
}
