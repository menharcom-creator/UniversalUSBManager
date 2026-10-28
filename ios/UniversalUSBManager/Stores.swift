import Foundation

struct Location: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let url: URL
}

final class Clipboard: ObservableObject {
    @Published var items: [URL] = []
    @Published var op: Op = .copy
}

/// iOS cannot enumerate USB drives for apps. The user picks a drive/folder once in the system file picker;
/// we keep a security-scoped bookmark so access survives relaunches.
final class LocationStore: ObservableObject {
    @Published private(set) var locations: [Location] = []
    private let key = "locations.v1"

    init() {
        let saved = UserDefaults.standard.array(forKey: key) as? [[String: Data]] ?? []
        for entry in saved {
            guard let data = entry["bookmark"] else { continue }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            _ = url.startAccessingSecurityScopedResource()
            locations.append(Location(name: url.lastPathComponent, url: url))
        }
    }

    func add(_ url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        guard !locations.contains(where: { $0.url == url }) else { return }
        locations.append(Location(name: url.lastPathComponent, url: url))
        persist()
    }

    func remove(_ loc: Location) {
        loc.url.stopAccessingSecurityScopedResource()
        locations.removeAll { $0.id == loc.id }
        persist()
    }

    private func persist() {
        let arr: [[String: Data]] = locations.compactMap { l in
            (try? l.url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)).map { ["bookmark": $0] }
        }
        UserDefaults.standard.set(arr, forKey: key)
    }
}
