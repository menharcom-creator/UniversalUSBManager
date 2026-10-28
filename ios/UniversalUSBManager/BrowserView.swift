import SwiftUI
import QuickLook

struct BrowserView: View {
    let root: URL
    let title: String
    @EnvironmentObject var queue: TransferQueue
    @EnvironmentObject var clipboard: Clipboard

    @State private var dir: URL
    @State private var back: [URL] = []
    @State private var fwd: [URL] = []
    @State private var items: [Item] = []
    @State private var loading = true
    @State private var error: String?
    @State private var sel = Set<URL>()
    @State private var sort = "Name"
    @State private var query = ""
    @State private var reload = 0
    @State private var preview: URL?
    @State private var message: String?
    @State private var showNewFolder = false
    @State private var showRename = false
    @State private var showDelete = false
    @State private var showPaste = false
    @State private var showDetails = false
    @State private var text = ""
    @State private var policy: ConflictPolicy = .keepBoth
    @State private var verify = false
    @State private var selBytes: Int64?

    init(root: URL, title: String) {
        self.root = root
        self.title = title
        _dir = State(initialValue: root)
    }

    private var shown: [Item] {
        let f = items.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        let cmp: (Item, Item) -> Bool
        switch sort {
        case "Size": cmp = { ($0.size ?? -1) < ($1.size ?? -1) }
        case "Date": cmp = { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        case "Type": cmp = { ($0.url.pathExtension.lowercased(), $0.name.lowercased()) < ($1.url.pathExtension.lowercased(), $1.name.lowercased()) }
        default: cmp = { $0.name.lowercased() < $1.name.lowercased() }
        }
        return f.sorted { a, b in a.isDir != b.isDir ? a.isDir : cmp(a, b) }
    }
    private var selected: [Item] { shown.filter { sel.contains($0.url) } }
    private var path: String { dir.path.replacingOccurrences(of: root.path, with: "") }

    var body: some View {
        VStack(spacing: 0) {
            Text("\(title)\(path)").font(.footnote).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
            if !sel.isEmpty {
                Text("\(sel.count) selected · total \(selBytes == nil ? "calculating…" : fmtSize(selBytes))").font(.footnote)
            }
            if loading { ProgressView().padding() }
            else if let e = error { Text(e).foregroundColor(.red).padding() }
            else if shown.isEmpty { Text(query.isEmpty ? "This folder is empty." : "No matches.").padding() }
            List(shown) { it in
                HStack {
                    Image(systemName: sel.contains(it.url) ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(.accentColor)
                        .onTapGesture { if sel.contains(it.url) { sel.remove(it.url) } else { sel.insert(it.url) } }
                    VStack(alignment: .leading) {
                        Text((it.isDir ? "📁 " : "📄 ") + it.name).lineLimit(1)
                        Text("\(it.isDir ? "Folder" : fmtSize(it.size)) · \(fmtDate(it.modified))").font(.footnote).foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture { if it.isDir { go(it.url) } else { preview = it.url } }
            }
            .listStyle(.plain)
        }
        .navigationTitle(dir.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query)
        .quickLookPreview($preview)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button { goBack() } label: { Image(systemName: "chevron.left") }.disabled(back.isEmpty)
                Button { goForward() } label: { Image(systemName: "chevron.right") }.disabled(fwd.isEmpty)
                Spacer()
                Button("Paste (\(clipboard.items.count))") { verify = false; showPaste = true }.disabled(clipboard.items.isEmpty)
                Menu("Actions") {
                    Button("Copy") { clipboard.items = selected.map(\.url); clipboard.op = .copy; message = "\(sel.count) item(s) copied" }.disabled(sel.isEmpty)
                    Button("Cut") { clipboard.items = selected.map(\.url); clipboard.op = .move; message = "\(sel.count) item(s) ready to move" }.disabled(sel.isEmpty)
                    Button("Delete…", role: .destructive) { showDelete = true }.disabled(sel.isEmpty)
                    Button("Rename…") { text = selected.first?.name ?? ""; showRename = true }.disabled(sel.count != 1)
                    Button("Details") { showDetails = true }.disabled(sel.count != 1)
                    Button("New folder…") { text = ""; showNewFolder = true }
                    Button("Select all") { sel = Set(shown.map(\.url)) }
                    Button("Deselect") { sel = [] }.disabled(sel.isEmpty)
                    Picker("Sort", selection: $sort) { ForEach(["Name", "Size", "Date", "Type"], id: \.self) { Text($0).tag($0) } }
                    Button("Refresh") { reload += 1 }
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                if sel.count == 1, let f = selected.first, !f.isDir { ShareLink(item: f.url) }
            }
        }
        .task(id: "\(dir.path)#\(reload)") { await load() }
        .task(id: sel) {
            selBytes = nil
            guard !sel.isEmpty else { return }
            let urls = Array(sel)
            selBytes = await Task.detached { urls.reduce(Int64(0)) { $0 + CopyEngine.countSize($1).bytes } }.value
        }
        .alert("New folder", isPresented: $showNewFolder) {
            TextField("Name", text: $text)
            Button("Create") { newFolder() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename", isPresented: $showRename) {
            TextField("Name", text: $text)
            Button("Rename") { rename() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete \(sel.count) item(s)?", isPresented: $showDelete) {
            Button("Delete", role: .destructive) { deleteSelected() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This permanently deletes the selected files and folders, including everything inside folders. It cannot be undone.") }
        .alert("Details", isPresented: $showDetails) { Button("OK", role: .cancel) {} } message: {
            if let f = selected.first { Text("\(f.name)\nSize: \(f.isDir ? "(see selection total)" : fmtSize(f.size))\nModified: \(fmtDate(f.modified))") }
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("OK", role: .cancel) {} }
        .sheet(isPresented: $showPaste) {
            NavigationStack {
                Form {
                    Section("If a file with the same name exists (applies to all conflicts in this operation)") {
                        Picker("Conflicts", selection: $policy) { ForEach(ConflictPolicy.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.inline)
                    }
                    Toggle("Verify with SHA-256 (slower, stronger)", isOn: $verify)
                    if clipboard.op == .move { Text("Sources are deleted only after the copy is verified.").font(.footnote) }
                }
                .navigationTitle(clipboard.op == .move ? "Move here" : "Copy here")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Start") { startPaste() } }
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showPaste = false } }
                }
            }
        }
    }

    private func go(_ u: URL) { back.append(dir); fwd = []; dir = u; sel = []; query = "" }
    private func goBack() { guard let p = back.popLast() else { return }; fwd.append(dir); dir = p; sel = [] }
    private func goForward() { guard let n = fwd.popLast() else { return }; back.append(dir); dir = n; sel = [] }

    private func load() async {
        loading = true
        error = nil
        let d = dir
        let result: Result<[Item], Error> = await Task.detached {
            do {
                let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
                let urls = try FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
                return .success(urls.map { u in
                    let v = try? u.resourceValues(forKeys: Set(keys))
                    return Item(url: u, isDir: v?.isDirectory ?? false, size: v?.fileSize.map { Int64($0) }, modified: v?.contentModificationDate)
                })
            } catch { return .failure(error) }
        }.value
        switch result {
        case .success(let i): items = i
        case .failure: items = []; error = "Cannot read this folder. The drive may have been disconnected or access was revoked."
        }
        loading = false
    }

    private func newFolder() {
        let name = text.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let t = dir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: t.path) { message = "A file or folder with that name already exists."; return }
        do { try FileManager.default.createDirectory(at: t, withIntermediateDirectories: false); reload += 1 }
        catch { message = "Could not create the folder (read-only or disconnected?)." }
    }

    private func rename() {
        guard let f = selected.first else { return }
        let name = text.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let t = f.url.deletingLastPathComponent().appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: t.path) { message = "That name is already in use."; return }
        do { try FileManager.default.moveItem(at: f.url, to: t); sel = []; reload += 1 }
        catch { message = "Rename failed (read-only, or unsupported characters)." }
    }

    private func deleteSelected() {
        var failed = 0
        for f in selected { do { try FileManager.default.removeItem(at: f.url) } catch { failed += 1 } }
        message = failed == 0 ? "Deleted." : "\(failed) item(s) could not be deleted (read-only or in use)."
        sel = []
        reload += 1
    }

    private func startPaste() {
        showPaste = false
        let ok = queue.enqueue(op: clipboard.op, sources: clipboard.items, destDir: dir, destLabel: "\(title)\(path)", policy: policy, verify: verify)
        if ok && clipboard.op == .move { clipboard.items = [] }
        message = ok ? "Added to the transfer queue." : "That transfer is already queued or running."
    }
}
