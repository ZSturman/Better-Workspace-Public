import Foundation

/// One app-owned identity attribute on explicitly created/edited content. Existing
/// originals are never marked by browsing. This is not a metadata sidecar, and no
/// other application's attributes are enumerated or read.
public enum WorkspaceContentIdentity {
    private static let name = "com.zacharysturman.betterworkspace.record"
    public struct Value: Codable, Equatable, Sendable {
        public let version: Int
        public let id: UUID
        public let kind: WorkspaceRecordContent.Kind
        public init(id: UUID, kind: WorkspaceRecordContent.Kind) { version = 1; self.id = id; self.kind = kind }
    }
    public static func read(at url: URL) throws -> Value? {
        try WorkspaceLocalPathChecks.rejectSymlinks(to: url)
        var bytes = [UInt8](repeating: 0, count: 512)
        let count = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return getxattr(path, name, &bytes, bytes.count, 0, XATTR_NOFOLLOW)
        }
        if count < 0 {
            if errno == ENOATTR || errno == ENOTSUP { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let value = try JSONDecoder().decode(Value.self, from: Data(bytes.prefix(count)))
        guard value.version == 1, [.note, .idea, .folder].contains(value.kind) else { throw WorkspaceReplicaError.unsupportedVersion }
        return value
    }
    public static func write(_ value: Value, at url: URL) throws {
        try WorkspaceLocalPathChecks.rejectSymlinks(to: url)
        let data = try JSONEncoder().encode(value)
        let result = data.withUnsafeBytes { bytes in
            url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return setxattr(path, name, bytes.baseAddress, data.count, 0, XATTR_NOFOLLOW)
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
