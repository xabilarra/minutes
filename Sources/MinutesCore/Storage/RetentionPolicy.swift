import Foundation

/// Decides which meeting videos have outlived their retention period. Audio and transcripts are always kept.
public struct RetentionPolicy: Sendable, Equatable {
    /// Days to keep `video.mp4`; nil = keep forever. Negative values also keep everything.
    public var videoRetentionDays: Int?

    public init(videoRetentionDays: Int?) {
        self.videoRetentionDays = videoRetentionDays
    }

    /// video.mp4 files under immediate subfolders of root whose meeting is older than N days (meta.json startedAt; folders without readable meta.json are skipped). Never returns anything else.
    ///
    /// The root itself may be a symbolic link (e.g. to an external disk); links inside it (to meeting
    /// folders or videos) are never followed. A missing root yields no files.
    public func videosToDelete(root: URL, now: Date, fileManager: FileManager = .default) throws -> [URL] {
        let directory = root.resolvingSymlinksInPath()
        guard let days = videoRetentionDays, days >= 0, fileManager.fileExists(atPath: directory.path) else {
            return []
        }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let videos = entries.compactMap { folder -> URL? in
            guard isPlainDirectory(folder),
                  let metadata = try? MetadataStore.read(from: folder),
                  metadata.startedAt < cutoff else {
                return nil
            }
            let video = folder.appendingPathComponent(MeetingFile.video.rawValue, isDirectory: false)
            return isRegularFile(video) ? video : nil
        }
        return videos.sorted { $0.path < $1.path }
    }

    private func isPlainDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private func isRegularFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }
}
