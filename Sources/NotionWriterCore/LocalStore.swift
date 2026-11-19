import Foundation
import Darwin

public final class LocalStore {
    public let root: URL
    private var lockFD: Int32?

    public init(root: URL, exclusive: Bool = false) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if exclusive {
            let lock = root.appendingPathComponent(".writer.lock")
            let fd = Darwin.open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if flock(fd, LOCK_EX | LOCK_NB) != 0 {
                let code = errno
                Darwin.close(fd)
                if code == EWOULDBLOCK {
                    throw WriterError.validation("Notion Writerがすでにこの下書きフォルダを使用しています。")
                }
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            lockFD = fd
        }
    }

    deinit {
        if let lockFD { Darwin.close(lockFD) }
    }
    public func read<T: Decodable>(_ type: T.Type, name: String) throws -> T? {
        let url = root.appendingPathComponent(name + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
    public func write<T: Encodable>(_ value: T, name: String) throws {
        let data = try JSONEncoder().encode(value)
        let url = root.appendingPathComponent(name + ".json")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public func draftName(for connection: Connection?) -> String { "draft-" + (connection.map { $0.databaseID + "-" + $0.dataSourceID } ?? "offline") }
}
