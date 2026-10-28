import Foundation

enum Op { case copy, move }

enum ConflictPolicy: String, CaseIterable, Identifiable {
    case keepBoth = "Keep both (rename incoming)"
    case replace = "Replace existing"
    case skip = "Skip"
    var id: String { rawValue }
}

enum JobState: String {
    case queued = "Queued", running = "Running", paused = "Paused", completed = "Completed"
    case warnings = "Completed with warnings", failed = "Failed", cancelled = "Cancelled", interrupted = "Interrupted"
}

struct Job: Identifiable {
    let id = UUID()
    let op: Op
    let sources: [URL]
    let destDir: URL
    let destLabel: String
    let policy: ConflictPolicy
    let verify: Bool
    var state: JobState = .queued
    var current = ""
    var total: Int64 = -1
    var done: Int64 = 0
    var filesTotal = 0
    var filesDone = 0
    var speed = 0.0
    var avg = 0.0
    var warnings: [String] = []
    var error: String?
    var isActive: Bool { state == .queued || state == .running || state == .paused }
}

struct Item: Identifiable, Hashable {
    var id: URL { url }
    let url: URL
    let isDir: Bool
    let size: Int64?
    let modified: Date?
    var name: String { url.lastPathComponent }
}

func fmtSize(_ b: Int64?) -> String {
    guard let b = b, b >= 0 else { return "Unknown" }
    return ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
}
func fmtSpeed(_ bps: Double) -> String { String(format: "%.1f MB/s", bps / 1_048_576) }
func fmtDate(_ d: Date?) -> String { d.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Unknown" }
