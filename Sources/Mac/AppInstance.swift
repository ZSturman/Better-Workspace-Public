import AppKit
import Darwin
import BetterWorkspaceCore

/// Installed and development copies share one menu bar owner. The kernel releases
/// the lock even after a crash; isolated tests and headless commands are independent.
@MainActor
enum AppInstance {
    static let reopenNotification = Notification.Name("com.zacharysturman.BetterWorkspace.reopenOwner")
    private static var descriptor: Int32 = -1

    static func claimOrExit() {
        guard !TestIsolation.isActive else { return }
        do {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("BetterWorkspace", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("app-instance.lock")
            descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                // Do not raise a window during a second login launch.
                if !LoginItem.wasLaunchedAtLogin(),
                   let pid = Int32(try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)),
                   let owner = NSRunningApplication(processIdentifier: pid),
                   owner.bundleIdentifier == Bundle.main.bundleIdentifier {
                    DistributedNotificationCenter.default().postNotificationName(
                        reopenNotification, object: String(pid), userInfo: nil, deliverImmediately: true)
                    owner.activate(options: [.activateAllWindows])
                }
                exit(0)
            }
            // Keep the descriptor open for the lifetime of the process. Never unlink:
            // replacing the inode would allow another copy to acquire a separate lock.
            let pid = Data("\(ProcessInfo.processInfo.processIdentifier)\n".utf8)
            guard ftruncate(descriptor, 0) == 0 else { throw POSIXError(.EIO) }
            let written = pid.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            guard written == pid.count else { throw POSIXError(.EIO) }
        } catch {
            FileHandle.standardError.write(Data("Better Workspace could not claim its menu bar instance: \(error)\n".utf8))
            exit(1)
        }
    }
}
