import Foundation
import UIKit

final class TransferQueue: ObservableObject {
    static let shared = TransferQueue()
    @Published private(set) var jobs: [Job] = []
    private var controls: [UUID: Control] = [:]
    private var running = false

    private struct Outcome {
        var state: JobState; var error: String?; var done: Int64; var avg: Double; var warnings: [String]
    }

    /// Returns false if an identical active job already exists (prevents duplicate taps).
    @discardableResult
    func enqueue(op: Op, sources: [URL], destDir: URL, destLabel: String, policy: ConflictPolicy, verify: Bool) -> Bool {
        if jobs.contains(where: { $0.isActive && $0.op == op && $0.destDir == destDir && $0.sources == sources }) { return false }
        let job = Job(op: op, sources: sources, destDir: destDir, destLabel: destLabel, policy: policy, verify: verify)
        controls[job.id] = Control()
        jobs.append(job)
        pump()
        return true
    }

    func pause(_ id: UUID) { controls[id]?.setPaused(true) }
    func resume(_ id: UUID) { controls[id]?.setPaused(false) }
    func cancel(_ id: UUID) {
        controls[id]?.setCancelled()
        mutate(id) { if $0.state == .queued { $0.state = .cancelled } }
    }
    func retry(_ id: UUID) {
        guard let j = jobs.first(where: { $0.id == id && !$0.isActive }) else { return }
        enqueue(op: j.op, sources: j.sources, destDir: j.destDir, destLabel: j.destLabel, policy: j.policy, verify: j.verify)
    }
    /// Removes finished entries from the list only; transferred files are never touched.
    func clearHistory() { jobs.removeAll { !$0.isActive } }

    private func mutate(_ id: UUID, _ f: @escaping (inout Job) -> Void) {
        let apply = { if let i = self.jobs.firstIndex(where: { $0.id == id }) { f(&self.jobs[i]) } }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }

    private func pump() {
        guard !running, let job = jobs.first(where: { $0.state == .queued }) else { return }
        running = true
        let control = controls[job.id] ?? Control()
        mutate(job.id) { $0.state = .running }
        var bg: UIBackgroundTaskIdentifier = .invalid
        // iOS only grants limited background time; if it expires we stop safely (temp file removed, source untouched).
        bg = UIApplication.shared.beginBackgroundTask(withName: "usbmgr-transfer") { control.setCancelled() }
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = self.execute(job, control)
            DispatchQueue.main.async {
                self.mutate(job.id) {
                    $0.state = outcome.state; $0.error = outcome.error; $0.done = outcome.done
                    $0.avg = outcome.avg; $0.warnings = outcome.warnings; $0.speed = 0; $0.current = ""
                }
                if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) }
                self.running = false
                self.pump()
            }
        }
    }

    private func execute(_ job: Job, _ control: Control) -> Outcome {
        var done: Int64 = 0, filesDone = 0, lastB: Int64 = 0
        var lastT = Date(); let start = Date()
        var warnings: [String] = []
        func avgNow() -> Double { Double(done) / max(Date().timeIntervalSince(start), 0.001) }
        let id = job.id
        do {
            for s in job.sources {
                var d: ObjCBool = false
                if FileManager.default.fileExists(atPath: s.path, isDirectory: &d), d.boolValue,
                   job.destDir.path == s.path || job.destDir.path.hasPrefix(s.path + "/") {
                    throw TransferError("A folder cannot be copied or moved into itself.")
                }
            }
            var files = 0; var bytes: Int64 = 0
            for s in job.sources { let r = CopyEngine.countSize(s); files += r.files; bytes += r.bytes }
            mutate(id) { $0.total = bytes; $0.filesTotal = files }

            let e = CopyEngine(policy: job.policy, verify: job.verify, control: control)
            e.onBytes = { n in
                done += n
                let now = Date(); let dt = now.timeIntervalSince(lastT)
                if dt >= 0.5 {
                    let speed = Double(done - lastB) / dt, avg = avgNow(), d = done
                    lastT = now; lastB = done
                    self.mutate(id) { $0.done = d; $0.speed = speed; $0.avg = avg }
                }
            }
            e.onFile = { n in self.mutate(id) { $0.current = n } }
            e.onFileDone = { filesDone += 1; let f = filesDone, d = done; self.mutate(id) { $0.filesDone = f; $0.done = d } }
            e.warn = { w in warnings.append(w); let all = warnings; self.mutate(id) { $0.warnings = all } }
            e.onPaused = { p in self.mutate(id) { $0.state = p ? .paused : .running; if p { $0.speed = 0 } }; if !p { lastT = Date(); lastB = done } }

            var all = true
            for s in job.sources { if !(try e.transferTop(s, to: job.destDir, move: job.op == .move)) { all = false } }
            return Outcome(state: (all && warnings.isEmpty) ? .completed : .warnings, error: nil, done: done, avg: avgNow(), warnings: warnings)
        } catch is Cancelled {
            return Outcome(state: .cancelled, error: "Cancelled. Source files were not changed; the file being copied was discarded.", done: done, avg: avgNow(), warnings: warnings)
        } catch let e as TransferError {
            return Outcome(state: .failed, error: e.message, done: done, avg: avgNow(), warnings: warnings)
        } catch {
            let ns = error as NSError
            let msg: String
            if ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC) { msg = "The destination storage is full." }
            else if ns.domain == NSPOSIXErrorDomain && ns.code == Int(EROFS) { msg = "The destination is read-only." }
            else { msg = "I/O error. The drive may have been disconnected, or an external HDD may need more power than this port supplies. The source was not modified and incomplete data was not marked as copied." }
            return Outcome(state: .interrupted, error: msg, done: done, avg: avgNow(), warnings: warnings)
        }
    }
}
