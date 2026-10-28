import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject var locations: LocationStore
    @EnvironmentObject var queue: TransferQueue
    @State private var picking = false
    @State private var tick = 0
    private let timer = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
            Section {
                Text("Active transfers: \(queue.jobs.filter { $0.isActive }.count) · Completed: \(queue.jobs.filter { $0.state == .completed || $0.state == .warnings }.count)")
            }
            Section("Locations") {
                if locations.locations.isEmpty {
                    Text("iOS doesn't let apps list USB drives automatically. Plug in the drive, tap \"Add location\" and pick it (or a folder on it) in the Files picker.")
                        .font(.footnote)
                }
                ForEach(locations.locations) { loc in
                    NavigationLink(value: loc) { LocationRow(loc: loc, tick: tick) }
                        .swipeActions { Button("Remove", role: .destructive) { locations.remove(loc) } }
                }
            }
            Section {
                Button("Add location…") { picking = true }
                Text("Actual speed depends on the slowest part of the chain: drive, cable/adapter, hub, the device's USB version, filesystem and destination write speed. iOS can only read filesystems it supports (typically FAT32, exFAT, APFS, HFS+).")
                    .font(.footnote)
            }
        }
        .navigationTitle("USB Storage Manager")
        .navigationDestination(for: Location.self) { BrowserView(root: $0.url, title: $0.name) }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { locations.add(url) }
        }
        .onReceive(timer) { _ in tick += 1 }
    }
}

struct LocationRow: View {
    let loc: Location
    let tick: Int
    var body: some View {
        let reachable = (try? loc.url.checkResourceIsReachable()) ?? false
        let v = try? loc.url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeNameKey])
        let total = v?.volumeTotalCapacity.map { Int64($0) }
        let free = v?.volumeAvailableCapacity.map { Int64($0) }
        VStack(alignment: .leading, spacing: 4) {
            Text(loc.name).font(.headline)
            Text(reachable ? "Connected" : "Not available (disconnected or access revoked)")
            Text("Capacity: \(fmtSize(total.flatMap { $0 > 0 ? $0 : nil })) · Free: \(fmtSize(free.flatMap { $0 > 0 ? $0 : nil }))").font(.footnote)
            Text("Filesystem: not exposed by iOS").font(.footnote)
        }
        .id(tick)
    }
}
