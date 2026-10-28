import SwiftUI

struct QueueView: View {
    @EnvironmentObject var queue: TransferQueue

    var body: some View {
        NavigationStack {
            List {
                if queue.jobs.isEmpty { Text("No transfers yet.") }
                ForEach(queue.jobs.reversed()) { JobCard(job: $0) }
            }
            .navigationTitle("Transfers")
            .toolbar { Button("Clear history") { queue.clearHistory() } }
            .safeAreaInset(edge: .bottom) {
                Text("Clearing history never deletes transferred files. Keep the app open for large transfers: iOS limits background time.")
                    .font(.footnote).padding(8)
            }
        }
    }
}

struct JobCard: View {
    let job: Job
    @EnvironmentObject var queue: TransferQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(job.op == .move ? "Move" : "Copy") · \(job.sources.count) item(s) → \(job.destLabel)").font(.headline)
            Text("Status: \(job.state.rawValue)")
            if !job.current.isEmpty && job.isActive { Text("Current file: \(job.current)").font(.footnote) }
            if job.total > 0 {
                ProgressView(value: Double(min(job.done, job.total)), total: Double(job.total))
                Text("\(fmtSize(job.done)) of \(fmtSize(job.total)) (\(job.done * 100 / job.total)%) · files \(job.filesDone)/\(job.filesTotal)").font(.footnote)
            }
            if job.state == .running {
                Text("Speed: \(fmtSpeed(job.speed)) (measured) · average \(fmtSpeed(job.avg))").font(.footnote)
                if job.avg > 0 && job.total > 0 {
                    Text("Estimated remaining: \(Int(Double(job.total - job.done) / job.avg)) s (estimate)").font(.footnote)
                }
            } else if job.avg > 0 { Text("Average speed: \(fmtSpeed(job.avg))").font(.footnote) }
            ForEach(Array(job.warnings.prefix(5).enumerated()), id: \.offset) { Text("⚠ \($0.element)").font(.footnote) }
            if let e = job.error { Text(e).foregroundColor(.red).font(.footnote) }
            HStack {
                if job.state == .running { Button("Pause") { queue.pause(job.id) }.buttonStyle(.bordered) }
                if job.state == .paused { Button("Resume") { queue.resume(job.id) }.buttonStyle(.bordered) }
                if job.isActive { Button("Cancel") { queue.cancel(job.id) }.buttonStyle(.bordered) }
                if [.failed, .interrupted, .cancelled].contains(job.state) { Button("Retry (restart)") { queue.retry(job.id) }.buttonStyle(.bordered) }
            }
        }
    }
}
