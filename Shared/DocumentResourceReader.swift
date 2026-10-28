import Foundation

struct DocumentResource {
    let handle: FileHandle
    let length: Int
    let mime: String
}

protocol DocumentResourceReader {
    /// Opens an absolute path for reading if `MediaPolicy` allows it.
    func open(path: String) async throws -> DocumentResource
}

/// Documents may embed local media from anywhere, but only media: other files are never returned,
/// so a renderer bug cannot turn `![](~/.ssh/id_ed25519)` into a leak. The type is checked again
/// on the file that was actually opened, after symlinks are resolved.
enum MediaPolicy {
    static let types: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp", "avif": "image/avif",
        "heic": "image/heic", "bmp": "image/bmp", "tif": "image/tiff", "tiff": "image/tiff", "ico": "image/x-icon", "svg": "image/svg+xml",
        "mp4": "video/mp4", "m4v": "video/x-m4v", "mov": "video/quicktime", "webm": "video/webm",
        "mp3": "audio/mpeg", "m4a": "audio/mp4", "aac": "audio/aac", "wav": "audio/wav", "aiff": "audio/aiff", "aif": "audio/aiff",
        "flac": "audio/flac", "ogg": "audio/ogg", "opus": "audio/ogg", "vtt": "text/vtt"
    ]
    static let streamed: Set<String> = ["mp4", "m4v", "mov", "webm", "mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "ogg", "opus"]
    static let sizeLimit = 50 << 20

    static let blocked = CocoaError(.fileReadUnsupportedScheme, userInfo: [NSLocalizedDescriptionKey: "Only images, audio, video, and subtitles can be embedded."])
    static let tooLarge = CocoaError(.fileReadTooLarge)

    static func mime(for path: String) -> String? { types[(path as NSString).pathExtension.lowercased()] }

    static func isAccessDenied(_ error: Error) -> Bool {
        if let error = error as? POSIXError { return error.code == .EPERM || error.code == .EACCES }
        return (error as? CocoaError)?.code == .fileReadNoPermission
    }

    /// HTTP-style status for a failed read, shared by the preview and the helper's replies.
    static func status(for error: Error) -> Int {
        if isAccessDenied(error) { return 403 }
        switch (error as? CocoaError)?.code {
        case blocked.code: return 415
        case tooLarge.code: return 413
        default: return [.ENOENT, .ENOTDIR].contains((error as? POSIXError)?.code) ? 404 : 500
        }
    }

    static func error(for status: Int) -> Error {
        switch status {
        case 403: return POSIXError(.EPERM)
        case 404: return POSIXError(.ENOENT)
        case 413: return tooLarge
        case 415: return blocked
        default: return POSIXError(.EIO)
        }
    }

    /// Opens a copy the helper already checked; it has no extension of its own.
    static func open(cached path: String, mime: String) throws -> DocumentResource {
        let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { Darwin.close(fd); throw POSIXError(.EIO) }
        return DocumentResource(handle: FileHandle(fileDescriptor: fd, closeOnDealloc: true), length: Int(info.st_size), mime: mime)
    }

    static func open(path: String) throws -> DocumentResource {
        guard path.hasPrefix("/"), mime(for: path) != nil else { throw blocked }
        let fd = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        var target = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fstat(fd, &info) == 0, fcntl(fd, F_GETPATH, &target) != -1 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let resolved = String(cString: target)
        guard info.st_mode & S_IFMT == S_IFREG, let mime = mime(for: resolved) else { throw blocked }
        let length = Int(info.st_size)
        if length > sizeLimit && !streamed.contains((resolved as NSString).pathExtension.lowercased()) { throw tooLarge }
        return DocumentResource(handle: handle, length: length, mime: mime)
    }
}

struct DirectResourceReader: DocumentResourceReader {
    func open(path: String) async throws -> DocumentResource {
        try await Task.detached(priority: .userInitiated) { try MediaPolicy.open(path: path) }.value
    }
}

/// Tries each reader in turn while access is denied, e.g. reading directly and then through the helper.
struct FallbackResourceReader: DocumentResourceReader {
    let readers: [DocumentResourceReader]
    func open(path: String) async throws -> DocumentResource {
        var denied: Error = CocoaError(.fileReadNoPermission)
        for reader in readers {
            do { return try await reader.open(path: path) } catch where MediaPolicy.isAccessDenied(error) { denied = error }
        }
        throw denied
    }
}
