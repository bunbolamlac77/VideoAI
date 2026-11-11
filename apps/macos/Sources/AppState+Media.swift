//
// AppState+Media.swift — folder selection, scanning and ffprobe (split from AppState).
//
// (P2-01) AppState had grown past 1.4k lines and mixed worker lifecycle, persistence,
// media scanning and gate wiring. Media/workspace handling is independent of the rest,
// so it lives here as an extension: no behaviour change, just a file a reviewer can read.
//

import SwiftUI
import AppKit

extension AppState {
    // MARK: - Folder & Media Selection

    nonisolated static let supportedVideoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "avi", "webm"
    ]
    nonisolated static let supportedImageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "webp", "tiff", "tif", "bmp"
    ]

    static func mediaKind(for url: URL) -> MediaItemKind? {
        let ext = url.pathExtension.lowercased()
        if supportedVideoExtensions.contains(ext) { return .video }
        if supportedImageExtensions.contains(ext) { return .image }
        return nil
    }

    /// Recursive enumeration can take seconds on large/external volumes — never run it on the main actor.
    func scanDirectoryAsync(at dirURL: URL) async -> [MediaSourceItem] {
        await Task.detached(priority: .userInitiated) {
            Self.scanDirectory(at: dirURL)
        }.value
    }

    nonisolated static let skippedDirectoryNames: Set<String> = [
        ".git", ".svn", ".hg", "CVS", ".venv", "venv", "node_modules",
        "DerivedData", ".build", "build", "__pycache__", "Pods", "Carthage"
    ]

    nonisolated static func scanDirectory(at dirURL: URL) -> [MediaSourceItem] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        guard let enumerator = fm.enumerator(
            at: dirURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var items: [MediaSourceItem] = []
        let maxItems = 5000

        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: Set(keys)) else {
                continue
            }

            if resourceValues.isDirectory ?? false {
                if Self.skippedDirectoryNames.contains(fileURL.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }

            let ext = fileURL.pathExtension.lowercased()
            let kind: MediaItemKind?
            if Self.supportedVideoExtensions.contains(ext) {
                kind = .video
            } else if Self.supportedImageExtensions.contains(ext) {
                kind = .image
            } else {
                kind = nil
            }

            if let kind = kind {
                let size = Int64(resourceValues.fileSize ?? 0)
                let date = resourceValues.contentModificationDate
                items.append(MediaSourceItem(
                    id: fileURL.path,
                    url: fileURL,
                    name: fileURL.lastPathComponent,
                    kind: kind,
                    fileSize: size,
                    modifiedDate: date
                ))
                if items.count >= maxItems {
                    break
                }
            }
        }

        return items.sorted {
            if $0.kind != $1.kind {
                return $0.kind == .video // Videos first
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    func selectSourceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Chọn thư mục"
        panel.message = "Chọn thư mục chứa toàn bộ video và ảnh tư liệu nguồn"

        if panel.runModal() == .OK, let url = panel.url {
            handleSelectedURL(url)
        }
    }

    func selectFileAndProbe() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Mở tư liệu"
        panel.message = "Chọn thư mục hoặc file video/ảnh nguồn"

        if panel.runModal() == .OK {
            if let first = panel.urls.first {
                if panel.urls.count == 1 && (first.hasDirectoryPath || (try? first.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true) {
                    handleSelectedURL(first)
                } else {
                    handleSelectedURLs(panel.urls)
                }
            }
        }
    }

    func handleSelectedURLs(_ urls: [URL]) {
        guard let first = urls.first else { return }
        if urls.count == 1 && (first.hasDirectoryPath || (try? first.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true) {
            handleSelectedURL(first)
            return
        }

        stopAccessingCurrentSecurityScopedResource()
        let fm = FileManager.default
        var items: [MediaSourceItem] = []

        for url in urls {
            let ext = url.pathExtension.lowercased()
            let kind: MediaItemKind?
            if Self.supportedVideoExtensions.contains(ext) {
                kind = .video
            } else if Self.supportedImageExtensions.contains(ext) {
                kind = .image
            } else {
                kind = nil
            }

            if let kind = kind {
                let attrs = try? fm.attributesOfItem(atPath: url.path)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                let date = attrs?[.modificationDate] as? Date
                items.append(MediaSourceItem(
                    id: url.path,
                    url: url,
                    name: url.lastPathComponent,
                    kind: kind,
                    fileSize: size,
                    modifiedDate: date
                ))
            }
        }

        self.mediaItems = items.sorted {
            if $0.kind != $1.kind { return $0.kind == .video }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }

        self.selectedDirectoryPath = first.deletingLastPathComponent().path
        if let target = items.first(where: { $0.kind == .video }) ?? items.first {
            selectItemForInspection(target)
        }
    }

    func populateSingleFile(url: URL) {
        guard let kind = Self.mediaKind(for: url) else {
            self.errorMessage = "Định dạng không được hỗ trợ: .\(url.pathExtension)"
            return
        }
        self.selectedDirectoryPath = url.deletingLastPathComponent().path
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let date = attrs?[.modificationDate] as? Date
        let singleItem = MediaSourceItem(
            id: url.path,
            url: url,
            name: url.lastPathComponent,
            kind: kind,
            fileSize: size,
            modifiedDate: date
        )
        self.mediaItems = [singleItem]
        selectItemForInspection(singleItem)
    }

    func handleSelectedURL(_ url: URL) {
        stopAccessingCurrentSecurityScopedResource()
        self.isBookmarkStale = false

        let isDir = url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true

        // Create Security-Scoped Bookmark for persistent access across app launches
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmarkData, forKey: "LastSelectedSourceFolderBookmark")
            self.isSecurityScoped = true
        } catch {
            self.isSecurityScoped = false
        }

        if isDir {
            let success = url.startAccessingSecurityScopedResource()
            if success {
                self.currentlyAccessedSecurityScopedURL = url
            }
            self.selectedDirectoryPath = url.path
            self.mediaItems = []
            self.statusMessage = "Đang quét thư mục: \(url.lastPathComponent)…"
            Task { await self.loadDirectory(url) }
        } else {
            // Single file selection
            populateSingleFile(url: url)
        }
    }

    /// Scans off-main, then applies results only if the user hasn't switched folders meanwhile.
    func loadDirectory(_ url: URL, keepSelection: Bool = false) async {
        let scanned = await scanDirectoryAsync(at: url)
        guard selectedDirectoryPath == url.path else { return }
        self.mediaItems = scanned
        self.statusMessage = "Đã nạp thư mục: \(url.lastPathComponent) (\(videoCount) video, \(imageCount) ảnh)"
        if keepSelection, scanned.contains(where: { $0.id == selectedFilePath }) { return }
        if let target = scanned.first(where: { $0.kind == .video }) ?? scanned.first {
            selectItemForInspection(target)
        } else {
            self.selectedFilePath = ""
            self.probeResult = nil
        }
    }

    func selectItemForInspection(_ item: MediaSourceItem) {
        self.selectedFilePath = item.id
        if item.kind == .video {
            Task {
                await self.probeFile(path: item.id)
            }
        } else {
            self.probeResult = nil
            self.isProbing = false
            self.statusMessage = "Đang xem ảnh đính kèm: \(item.name) (\(item.formattedSize))"
        }
    }

    func refreshCurrentDirectory() {
        guard !selectedDirectoryPath.isEmpty else { return }
        let url = URL(fileURLWithPath: selectedDirectoryPath)
        self.statusMessage = "Đang quét lại thư mục…"
        Task { await self.loadDirectory(url, keepSelection: true) }
    }

    func restoreSavedBookmark() {
        stopAccessingCurrentSecurityScopedResource()
        var isStale = false

        if let data = UserDefaults.standard.data(forKey: "LastSelectedSourceFolderBookmark") {
            do {
                let restoredURL = try URL(
                    resolvingBookmarkData: data,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                self.isBookmarkStale = isStale
                // A stale bookmark still resolves; Apple's guidance is to access it and re-mint the bookmark.
                let success = restoredURL.startAccessingSecurityScopedResource()
                if success {
                    self.currentlyAccessedSecurityScopedURL = restoredURL
                    if isStale,
                       let fresh = try? restoredURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                        UserDefaults.standard.set(fresh, forKey: "LastSelectedSourceFolderBookmark")
                        self.isBookmarkStale = false
                    }
                    let isDir = restoredURL.hasDirectoryPath || (try? restoredURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                    if isDir {
                        self.selectedDirectoryPath = restoredURL.path
                        Task { await self.loadDirectory(restoredURL) }
                    } else {
                        populateSingleFile(url: restoredURL)
                    }
                } else if isStale {
                    self.errorMessage = "Quyền truy cập thư mục đã cũ (stale bookmark). Vui lòng chọn lại thư mục để tái cấp quyền."
                } else {
                    self.errorMessage = "Không thể cấp quyền truy cập security-scoped cho thư mục đã lưu."
                }
                return
            } catch {
                // Fallback to legacy single file bookmark
            }
        }

        // Legacy file bookmark fallback
        if let data = UserDefaults.standard.data(forKey: "LastSelectedSourceBookmark") {
            do {
                let restoredURL = try URL(
                    resolvingBookmarkData: data,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                self.isBookmarkStale = isStale
                if isStale {
                    self.errorMessage = "Quyền truy cập file đã cũ. Vui lòng chọn lại file."
                } else {
                    let success = restoredURL.startAccessingSecurityScopedResource()
                    if success {
                        self.currentlyAccessedSecurityScopedURL = restoredURL
                        populateSingleFile(url: restoredURL)
                    }
                }
            } catch {
                self.errorMessage = "Không thể khôi phục bookmark: \(error.localizedDescription)"
            }
        }
    }

    func probeFile(path: String) async {
        self.isProbing = true
        self.errorMessage = nil
        defer { if selectedFilePath == path || selectedFilePath.isEmpty { isProbing = false } }
        do {
            let res = try await worker.probeMedia(filePath: path)
            // Drop stale results: user may have clicked another item while ffprobe ran.
            guard selectedFilePath == path else { return }
            self.probeResult = res
            self.statusMessage = "Phân tích media thành công: \(URL(fileURLWithPath: path).lastPathComponent)"
        } catch {
            guard selectedFilePath == path else { return }
            self.errorMessage = "Lỗi probe media: \(error.localizedDescription)"
            self.probeResult = nil
        }
    }

}
