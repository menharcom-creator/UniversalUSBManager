import Foundation
import CryptoKit

struct Cancelled: Error {}
struct TransferError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

final class Control {
    private let l = NSLock()
    private var c = false, p = false
    var cancelled: Bool { l.lock(); defer { l.unlock() }; return c }
    var paused: Bool { l.lock(); defer { l.unlock() }; return p }
    func setCancelled() { l.lock(); c = true; l.unlock() }
    func setPaused(_ v: Bool) { l.lock(); p = v; l.unlock() }
}

/// Safe copy/move: temp file -> fsync -> size check -> source-unchanged check -> optional SHA-256 -> rename.
/// Sources are deleted (moves) only after verification. Mirrors the Android CopyEngine.
final class CopyEngine {
    let policy: ConflictPolicy
    let verify: Bool
    let control: Control
    var onBytes: (Int64) -> Void = { _ in }
    var onFile: (String) -> Void = { _ in }
    var onFileDone: () -> Void = {}
    var warn: (String) -> Void = { _ in }
    var onPaused: (Bool) -> Void = { _ in }
    private let fm = FileManager.default

    init(policy: ConflictPolicy, verify: Bool, control: Control) {
        self.policy = policy; self.verify = verify; self.control = control
    }

    func checkpoint() throws {
        var was = false
        while control.paused && !control.cancelled {
            if !was { was = true; onPaused(true) }
            Thread.sleep(forTimeInterval: 0.2)
        }
        if was { onPaused(false) }
        if control.cancelled { throw Cancelled() }
    }

    static func countSize(_ url: URL) -> (files: Int, bytes: Int64) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return (0, 0) }
        if !isDir.boolValue {
            let s = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            return (1, s)
        }
        var f = 0; var b: Int64 = 0
        for c in (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [] {
            let r = countSize(c); f += r.files; b += r.bytes
        }
        return (f, b)
    }

    /// Returns true only if everything was transferred (nothing skipped / left behind).
    func transferTop(_ src: URL, to destDir: URL, move: Bool) throws -> Bool {
        try checkpoint()
        let target = destDir.appendingPathComponent(src.lastPathComponent)
        if move, !fm.fileExists(atPath: target.path), sameVolume(src, destDir) {
            do {
                onFile(src.lastPathComponent)
                let size = Self.countSize(src).bytes
                try fm.moveItem(at: src, to: target)   // same-volume rename, no data copied
                onBytes(size); onFileDone()
                return true
            } catch { /* fall back to copy + verify + delete */ }
        }
        return try transfer(src, to: destDir, move: move)
    }

    private func sameVolume(_ a: URL, _ b: URL) -> Bool {
        guard let x = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject,
              let y = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject else { return false }
        return x.isEqual(y)
    }

    private func transfer(_ src: URL, to destDir: URL, move: Bool) throws -> Bool {
        try checkpoint()
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: src.path, isDirectory: &isDir) else {
            throw TransferError("The source \"\(src.lastPathComponent)\" is missing or no longer accessible.")
        }
        return isDir.boolValue ? try copyDir(src, to: destDir, move: move) : try copyFile(src, to: destDir, move: move)
    }

    private func uniqueName(_ name: String, in dir: URL) -> String {
        let ns = name as NSString
        let ext = ns.pathExtension, base = ns.deletingPathExtension
        var i = 1
        while true {
            let cand = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            if !fm.fileExists(atPath: dir.appendingPathComponent(cand).path) { return cand }
            i += 1
        }
    }

    private func copyDir(_ src: URL, to destDir: URL, move: Bool) throws -> Bool {
        var target = destDir.appendingPathComponent(src.lastPathComponent)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: target.path, isDirectory: &isDir) {
            if !isDir.boolValue { // a file has this folder's name: never overwrite it
                target = destDir.appendingPathComponent(uniqueName(src.lastPathComponent, in: destDir))
                try makeDir(target)
            } // else: merge into the existing folder
        } else { try makeDir(target) }
        var all = true
        let children = try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        for c in children { if !(try transfer(c, to: target, move: move)) { all = false } }
        if move && all {
            do { try fm.removeItem(at: src) } catch { warn("Copied, but the source folder \"\(src.lastPathComponent)\" could not be removed."); all = false }
        }
        return all
    }

    private func makeDir(_ url: URL) throws {
        do { try fm.createDirectory(at: url, withIntermediateDirectories: false) }
        catch { throw TransferError("Cannot create folder \"\(url.lastPathComponent)\". The destination may be read-only or disconnected.") }
    }

    private func attrs(_ url: URL) throws -> (size: Int64, mod: Date?) {
        do {
            let a = try fm.attributesOfItem(atPath: url.path)
            return ((a[.size] as? NSNumber)?.int64Value ?? -1, a[.modificationDate] as? Date)
        } catch { throw TransferError("\"\(url.lastPathComponent)\" is missing or no longer accessible.") }
    }

    private func copyFile(_ src: URL, to destDir: URL, move: Bool) throws -> Bool {
        let name = src.lastPathComponent
        onFile(name)
        let before = try attrs(src)
        var finalName = name
        var replace = false
        let existing = destDir.appendingPathComponent(name)
        if fm.fileExists(atPath: existing.path) {
            if existing.standardizedFileURL == src.standardizedFileURL {
                warn("Skipped \"\(name)\": source and destination are the same file.")
                onBytes(max(before.size, 0)); onFileDone(); return false
            }
            switch policy {
            case .skip:
                warn("Skipped \"\(name)\": a file with this name already exists.")
                onBytes(max(before.size, 0)); onFileDone(); return false
            case .keepBoth: finalName = uniqueName(name, in: destDir)
            case .replace:
                var d: ObjCBool = false
                _ = fm.fileExists(atPath: existing.path, isDirectory: &d)
                if d.boolValue { throw TransferError("A folder named \"\(name)\" already exists at the destination.") }
                replace = true
            }
        }
        // Free space is only trusted when iOS reports a positive value (external drives often report nothing useful).
        if let free = (try? destDir.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity,
           free > 0, before.size > Int64(free) {
            throw TransferError("Not enough free space on the destination for \"\(name)\" (needs \(fmtSize(before.size)), \(fmtSize(Int64(free))) free).")
        }

        let tmp = destDir.appendingPathComponent(".\(finalName).usbmgr-part")
        guard fm.createFile(atPath: tmp.path, contents: nil) else {
            throw TransferError("Cannot create a file at the destination. It may be read-only, write-protected or disconnected.")
        }
        let bufSize = before.size <= 8 << 20 ? 256 << 10 : (before.size > 1 << 30 ? 4 << 20 : 1 << 20)
        var hasher = SHA256()
        var copied: Int64 = 0
        // We created tmp in this run, so we may delete it if anything fails before verification.
        do {
            let rh = try FileHandle(forReadingFrom: src)
            defer { try? rh.close() }
            let wh = try FileHandle(forWritingTo: tmp)
            defer { try? wh.close() }
            var eof = false
            while !eof {
                try checkpoint()
                try autoreleasepool {
                    guard let d = try rh.read(upToCount: bufSize), !d.isEmpty else { eof = true; return }
                    try wh.write(contentsOf: d)
                    if verify { hasher.update(data: d) }
                    copied += Int64(d.count)
                    onBytes(Int64(d.count))
                }
            }
            try wh.synchronize()
            let written = try attrs(tmp).size
            if written != copied { throw TransferError("Verification failed for \"\(name)\": copied \(copied) bytes but the destination reports \(written).") }
            if before.size >= 0 && copied != before.size { throw TransferError("Verification failed for \"\(name)\": expected \(before.size) bytes, copied \(copied).") }
            let after = try? attrs(src)
            if after == nil || after!.size != before.size || after!.mod != before.mod {
                throw TransferError("\"\(name)\" was modified or removed while it was being copied. Nothing was changed at the destination.")
            }
            if verify {
                let dst = try sha256(of: tmp)
                if dst != Array(hasher.finalize()) { throw TransferError("Verification failed for \"\(name)\": checksum mismatch. The source file was left untouched.") }
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }

        // Verified: finalize.
        let final = destDir.appendingPathComponent(finalName)
        if replace {
            do { try fm.removeItem(at: existing) }
            catch { throw TransferError("Verified copy of \"\(name)\" is kept as \"\(tmp.lastPathComponent)\", but the existing file could not be replaced.") }
        }
        do { try fm.moveItem(at: tmp, to: final) }
        catch { throw TransferError("Copy of \"\(name)\" is verified but could not be renamed. It is kept as \"\(tmp.lastPathComponent)\" at the destination.") }

        if move {
            do { try fm.removeItem(at: src) }
            catch { warn("Copied and verified \"\(name)\", but the source could not be deleted."); onFileDone(); return false }
        }
        onFileDone()
        return true
    }

    private func sha256(of url: URL) throws -> [UInt8] {
        var h = SHA256()
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var eof = false
        while !eof {
            try checkpoint()
            try autoreleasepool {
                guard let d = try fh.read(upToCount: 1 << 20), !d.isEmpty else { eof = true; return }
                h.update(data: d)
            }
        }
        return Array(h.finalize())
    }
}
