# Captured keyboard and fullscreen hangs

Four October 31 samples are retained under `/Users/wsb/yina/yina-traces/automatic-hangs`. Three contain MainWindow.keyDown -> menu key-equivalent traversal -> RecentDocumentsMenuController.menuNeedsUpdate -> NSDocumentController.recentDocumentURLs -> operation wait. The worker resolves recent-file bookmarks via synchronous ScopedBookmarksAgent IPC. The fourth blocks in file resource metadata lookup while AppKit refreshes the represented document during fullscreen exit/termination.

Recent menu updates now use a cached list. Opening the menu starts one background refresh; keyboard traversal never invokes the resolver. A generation rejects a reply predating Clear Menu. The provider reads persisted plain URL strings, seeded from existing playback history until the first new item or Clear Menu. It never calls the main-actor NSDocumentController resolver from a worker. New recent-file registrations maintain the bounded 20-item cache. Menu mutation stays on main.

For paths under /Volumes, the title remains the filename, respecting extension preferences, but the window no longer carries a represented URL or represented filename. This removes the automatic proxy-icon metadata query during fullscreen transitions. Local files elsewhere retain their native proxy icon. Custom mount points outside /Volumes are not covered by this lexical policy.

The native main-menu smoke test deliberately blocks the recent URL provider, verifies immediate menu handling, releases the provider, and validates populated items and Clear Menu alongside all 69 menu contract checks. The actual NAS and fullscreen hang still require user verification after installing and restarting. The existing automatic hang watcher remains enabled.
