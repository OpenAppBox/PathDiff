//
//  BookmarkStore.swift
//  PathDiff
//

import Foundation

/// A previously compared folder pair, persisted with security-scoped bookmarks so the
/// sandboxed app can reopen it after relaunch.
nonisolated struct RecentComparison: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var leftPath: String
    var rightPath: String
    var leftBookmark: Data
    var rightBookmark: Data
    var lastOpened: Date

    var leftName: String { (leftPath as NSString).lastPathComponent }
    var rightName: String { (rightPath as NSString).lastPathComponent }
    var title: String { "\(leftName) ↔ \(rightName)" }
}

nonisolated enum BookmarkStore {
    /// Creates an app-scoped, security-scoped bookmark (requires the
    /// `com.apple.security.files.bookmarks.app-scope` entitlement).
    static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Resolves without user interface. Unless `allowsMounting`, a bookmark to a volume
    /// that isn't mounted (a disconnected server or drive) fails instead of blocking while
    /// the system tries to mount it.
    static func resolve(_ data: Data, allowsMounting: Bool = false) -> URL? {
        var isStale = false
        var options: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
        if !allowsMounting { options.insert(.withoutMounting) }
        return try? URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &isStale)
    }
}

/// Keeps a security-scoped resource accessible for as long as the object is alive.
nonisolated final class SecurityScopedAccess: Sendable {
    let url: URL
    private let didStart: Bool

    init(url: URL) {
        self.url = url
        self.didStart = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if didStart { url.stopAccessingSecurityScopedResource() }
    }
}

/// Asks for a new window comparing two specific folders (e.g. a moved folder and its new
/// location). Bookmarks keep sandbox access when the window is restored after relaunch.
nonisolated struct ComparisonRequest: Codable, Hashable, Sendable {
    let leftBookmark: Data
    let rightBookmark: Data
}
