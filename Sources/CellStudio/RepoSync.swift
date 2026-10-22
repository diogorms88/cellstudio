import Foundation
import SwiftUI

// Ligação com o repositório do GitHub (github.com/diogorms88/cellstudio):
// - versão: compara o commit desta compilação com o último commit do GitHub;
// - Download: baixa estações (pasta "flash's") e arquivos 3D (pasta "bodies") para o aparelho.
// O repositório é público; a listagem usa a API do GitHub e os arquivos vêm de raw.githubusercontent.com.

enum RepoInfo {
    static let owner = "diogorms88"
    static let name = "cellstudio"
    static let branch = "main"
    static let flashFolder = "flash's"
    static let bodiesFolder = "bodies"
    static var page: URL { URL(string: "https://github.com/\(owner)/\(name)")! }
}

/// Commit gravado em build-info.json na compilação (build.sh, build-ios.sh e o projeto Xcode).
struct BuildInfo: Decodable {
    var commit: String
    var date: String?

    static let current: BuildInfo? = Bundle.main.url(forResource: "build-info", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap { try? JSONDecoder().decode(BuildInfo.self, from: $0) }

    var short: String { String(commit.prefix(7)) }
}

/// Um robô (backup do flash em flash's) ou um arquivo/pasta 3D (em bodies) do repositório.
/// Em flash's, `name` é o caminho do robô: "Módulo/[Estação/]Robô" (ex.: "Avulso/R11", "VW A/6010/…_6010_R11").
struct RemoteItem: Identifiable {
    enum Kind { case flash, body }
    struct File { let path: String; let sha: String; let size: Int }

    let kind: Kind
    let name: String
    let isFolder: Bool
    var files: [File]

    private var parts: [String] { name.split(separator: "/").map(String.init) }
    /// primeira pasta dentro de flash's (Avulso, VW A…)
    var module: String { parts.count > 1 ? parts[0] : "" }
    /// pastas entre o módulo e o robô (ex.: "6010"); vazio para robôs soltos no módulo
    var station: String { parts.count > 2 ? parts[1..<(parts.count - 1)].joined(separator: " / ") : "" }
    /// nome curto: "…_6010_R11" → "R11"
    var label: String {
        let last = parts.last ?? name
        if let r = last.range(of: #"_(R\d+)$"#, options: .regularExpression) { return String(last[r].dropFirst()) }
        return last
    }

    var id: String { repoPath }
    var repoPath: String { (kind == .flash ? RepoInfo.flashFolder : RepoInfo.bodiesFolder) + "/" + name }
    var size: Int { files.reduce(0) { $0 + $1.size } }
    var localURL: URL { RepoSync.localRoot(kind).appendingPathComponent(name, isDirectory: isFolder) }
}

@MainActor
final class RepoSync: ObservableObject {
    static let shared = RepoSync()

    @Published private(set) var items: [RemoteItem] = []
    /// último commit do branch (os arquivos baixados vêm dele)
    @Published private(set) var latestCommit: String?
    /// último commit que mudou o app (comparado com BuildInfo.current)
    @Published private(set) var latestCode: String?
    @Published private(set) var latestMessage: String?
    @Published private(set) var loading = false
    @Published var error: String?
    /// item → fração baixada (0…1) enquanto baixa
    @Published private(set) var progress: [String: Double] = [:]
    /// caminho no repositório → sha do arquivo baixado (para baixar só o que mudou)
    @Published private(set) var manifest: [String: String] = RepoSync.loadManifest()

    var updateAvailable: Bool {
        guard let latest = latestCode, let mine = BuildInfo.current?.commit, mine != "dev" else { return false }
        return latest != mine
    }

    // MARK: Pastas locais

    /// iPhone: Documentos do app (Arquivos ▸ No meu iPhone ▸ CellStudio). Mac: ~/Documents/CellStudio.
    nonisolated static var downloadsRoot: URL {
        Platform.isMac ? Platform.documents.appendingPathComponent("CellStudio", isDirectory: true) : Platform.documents
    }

    nonisolated static func localRoot(_ kind: RemoteItem.Kind) -> URL {
        downloadsRoot.appendingPathComponent(kind == .flash ? "Flash" : "Bodies", isDirectory: true)
    }

    nonisolated private static var manifestURL: URL { downloadsRoot.appendingPathComponent(".cellstudio-downloads.json") }

    nonisolated private static func loadManifest() -> [String: String] {
        (try? Data(contentsOf: manifestURL)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    private func saveManifest() {
        try? FileManager.default.createDirectory(at: Self.downloadsRoot, withIntermediateDirectories: true)
        try? JSONEncoder().encode(manifest).write(to: Self.manifestURL)
    }

    enum Status { case missing, outdated, current }

    func status(_ item: RemoteItem) -> Status {
        let have = item.files.filter { manifest[$0.path] != nil }
        if have.isEmpty || !FileManager.default.fileExists(atPath: item.localURL.path) { return .missing }
        return item.files.allSatisfy { manifest[$0.path] == $0.sha } ? .current : .outdated
    }

    // MARK: GitHub

    private static func api(_ path: String) async throws -> Any {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(RepoInfo.owner)/\(RepoInfo.name)/\(path)")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let msg = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["message"] as? String ?? ""
            throw NSError(domain: "GitHub", code: status, userInfo: [NSLocalizedDescriptionKey:
                status == 403 ? "Limite de consultas do GitHub atingido; tente de novo em alguns minutos." : "GitHub \(status): \(msg)"])
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// Último commit que mudou o código (Sources/), para o aviso de versão nova; envios de dados não contam.
    /// Silencioso: sem rede, não avisa.
    func checkForUpdate() async {
        guard let list = try? await Self.api("commits?sha=\(RepoInfo.branch)&path=Sources&per_page=1") as? [[String: Any]],
              let commit = list.first, let sha = commit["sha"] as? String else { return }
        latestCode = sha
        latestMessage = ((commit["commit"] as? [String: Any])?["message"] as? String)?.components(separatedBy: "\n").first
    }

    /// Lista as estações e os arquivos 3D do repositório.
    func refresh() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            await checkForUpdate()
            if let branch = try await Self.api("branches/\(RepoInfo.branch)") as? [String: Any],
               let commit = branch["commit"] as? [String: Any] { latestCommit = commit["sha"] as? String }
            guard let ref = latestCommit else { throw NSError(domain: "GitHub", code: 0, userInfo: [NSLocalizedDescriptionKey: "Sem conexão com o GitHub"]) }
            guard let tree = try await Self.api("git/trees/\(ref)?recursive=1") as? [String: Any],
                  let entries = tree["tree"] as? [[String: Any]] else { return }
            let blobs = entries.filter { $0["type"] as? String == "blob" }
            // robôs em flash's: a pasta acima de config/machinedata1.cfg (ou de application/control/config/…)
            let flashPrefix = RepoInfo.flashFolder + "/"
            let robotRoots = blobs.compactMap { $0["path"] as? String }.filter { $0.hasPrefix(flashPrefix) }.compactMap { path -> String? in
                guard path.lowercased().hasSuffix("/config/machinedata1.cfg") else { return nil }
                var root = String(path.dropLast("/config/machinedata1.cfg".count))
                if root.lowercased().hasSuffix("/application/control") { root = String(root.dropLast("/application/control".count)) }
                return root.count > flashPrefix.count ? String(root.dropFirst(flashPrefix.count)) : nil
            }.sorted { $0.count > $1.count }          // o mais fundo primeiro
            var byKey: [String: RemoteItem] = [:]
            for e in blobs {
                guard let path = e["path"] as? String, let sha = e["sha"] as? String else { continue }
                let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
                guard parts.count >= 2 else { continue }
                let file = RemoteItem.File(path: path, sha: sha, size: e["size"] as? Int ?? 0)
                switch parts[0] {
                case RepoInfo.flashFolder:
                    // arquivo pertence ao robô cuja pasta o contém; READMEs e soltos ficam de fora
                    let rel = String(path.dropFirst(flashPrefix.count))
                    guard let root = robotRoots.first(where: { rel.hasPrefix($0 + "/") }) else { continue }
                    let key = flashPrefix + root
                    var item = byKey[key] ?? RemoteItem(kind: .flash, name: root, isFolder: true, files: [])
                    item.files.append(file)
                    byKey[key] = item
                case RepoInfo.bodiesFolder:
                    let name = parts[1]
                    if parts.count == 2, name.hasPrefix(".") || name.lowercased() == "readme.md" { continue }
                    let key = parts[0] + "/" + name
                    var item = byKey[key] ?? RemoteItem(kind: .body, name: name, isFolder: parts.count > 2, files: [])
                    item.files.append(file)
                    byKey[key] = item
                default: continue
                }
            }
            items = byKey.values.sorted { ($0.kind == .flash ? 0 : 1, $0.name.lowercased()) < ($1.kind == .flash ? 0 : 1, $1.name.lowercased()) }
            if tree["truncated"] as? Bool == true { error = "O repositório tem arquivos demais para listar de uma vez; a lista pode estar incompleta." }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Baixa (ou atualiza) um item; só os arquivos novos ou alterados descem.
    @discardableResult
    func download(_ item: RemoteItem) async -> Bool {
        guard progress[item.id] == nil, let ref = latestCommit else { return false }
        let pending = item.files.filter { manifest[$0.path] != $0.sha || !FileManager.default.fileExists(atPath: localFile(item, $0).path) }
        let total = max(pending.reduce(0) { $0 + $1.size }, 1)
        progress[item.id] = 0
        defer { progress[item.id] = nil; saveManifest() }
        var done = 0
        do {
            // 6 arquivos por vez
            try await withThrowingTaskGroup(of: (RemoteItem.File, URL).self) { group in
                var queue = pending[...]
                func next() {
                    guard let f = queue.popFirst() else { return }
                    let dest = localFile(item, f)
                    group.addTask { try await (f, Self.fetch(f.path, ref: ref, to: dest)) }
                }
                for _ in 0..<6 { next() }
                while let (f, _) = try await group.next() {
                    manifest[f.path] = f.sha
                    done += f.size
                    progress[item.id] = Double(done) / Double(total)
                    next()
                }
            }
            AppState.shared?.info("Download: \(item.name) – \(pending.count) arquivo(s) em \(item.localURL.path)")
            return true
        } catch {
            self.error = "\(item.name): \(error.localizedDescription)"
            return false
        }
    }

    nonisolated private func localFile(_ item: RemoteItem, _ f: RemoteItem.File) -> URL {
        // caminho dentro do item (pasta) ou o próprio arquivo
        let rel = f.path.dropFirst(item.repoPath.count + 1)
        return item.isFolder ? item.localURL.appendingPathComponent(String(rel)) : item.localURL
    }

    nonisolated private static func fetch(_ path: String, ref: String, to dest: URL) async throws -> URL {
        let encoded = path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["'"])) ?? String($0) }
        let url = URL(string: "https://raw.githubusercontent.com/\(RepoInfo.owner)/\(RepoInfo.name)/\(ref)/" + encoded.joined(separator: "/"))!
        let (tmp, resp) = try await URLSession.shared.download(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "GitHub", code: (resp as? HTTPURLResponse)?.statusCode ?? 0,
                          userInfo: [NSLocalizedDescriptionKey: "falha ao baixar \(path)"])
        }
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: tmp, to: dest)
        return dest
    }
}

// MARK: - Tela de Download

struct DownloadsView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var repo = RepoSync.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("Aplicativo") { versionRow }
            Section {
                let robots = repo.items.filter { $0.kind == .flash }
                let modules = Array(Set(robots.map(\.module))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                if robots.isEmpty, !repo.loading { Text("Nada em \(RepoInfo.flashFolder) no GitHub").foregroundStyle(.secondary) }
                ForEach(modules, id: \.self) { m in
                    let list = robots.filter { $0.module == m }
                    NavigationLink { ModuleDownloadsView(module: m) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "folder.fill").foregroundStyle(Color(red: 0.95, green: 0.75, blue: 0.3)).frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(m.isEmpty ? "Sem módulo" : m).font(.system(size: 15, weight: .semibold))
                                Text(moduleSummary(list)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Estações (\(RepoInfo.flashFolder))")
            } footer: {
                Text("Um módulo por pasta (Avulso, VW A…). Dentro dele, os robôs de cada estação.")
            }
            Section {
                ForEach(repo.items.filter { $0.kind == .body }) { DownloadRow(item: $0) }
                if !repo.items.contains(where: { $0.kind == .body }), !repo.loading {
                    Text("Nada em \(RepoInfo.bodiesFolder) no GitHub").foregroundStyle(.secondary)
                }
            } header: {
                Text("Arquivos 3D (\(RepoInfo.bodiesFolder))")
            } footer: {
                Text("Carrocerias e peças (HSF/STL/OBJ/USDZ). Uma pasta com Robots/ e Tools/ (a 3DObjects do DXQ) vira a biblioteca de modelos dos robôs.")
            }
            if let e = repo.error {
                Section { Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
        }
        .overlay { if repo.loading && repo.items.isEmpty { ProgressView("Consultando o GitHub…") } }
        .refreshable { await repo.refresh() }
        .task { await repo.refresh() }
        .navigationTitle("Download")
        .navigationBarTitleDisplayModeInline()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button { Task { await repo.refresh() } } label: { Image(systemName: "arrow.clockwise") }.disabled(repo.loading)
            }
            if Platform.isMac {
                ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } }
            }
        }
    }

    @ViewBuilder private var versionRow: some View {
        let mine = BuildInfo.current
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Instalada")
                Spacer()
                Text(mine.map { $0.commit == "dev" ? "desenvolvimento" : $0.short } ?? "desconhecida").font(.system(.body, design: .monospaced))
            }
            HStack {
                Text("No GitHub")
                Spacer()
                Text(repo.latestCode.map { String($0.prefix(7)) } ?? "…").font(.system(.body, design: .monospaced))
            }
            if repo.updateAvailable {
                Label("Versão nova: \(repo.latestMessage ?? "")", systemImage: "arrow.down.app").foregroundStyle(.blue)
                Text(Platform.isMac ? "No Mac: git pull e ./build.sh. O serviço de atualização instala a nova versão no iPhone."
                                    : "O Mac instala a nova versão sozinho quando o iPhone estiver no cabo ou na mesma rede Wi-Fi.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if repo.latestCode != nil {
                Label("Atualizado", systemImage: "checkmark.circle").foregroundStyle(.green)
            }
        }
        .font(DXQ.font)
    }

    private func moduleSummary(_ list: [RemoteItem]) -> String {
        let stations = Set(list.map(\.station)).filter { !$0.isEmpty }
        let size = ByteCountFormatter.string(fromByteCount: Int64(list.reduce(0) { $0 + $1.size }), countStyle: .file)
        return (stations.isEmpty ? "" : "\(stations.count) estação(ões) · ") + "\(list.count) robô(s) · \(size)"
    }

}

/// Mensagem única quando o GitHub tem uma versão mais nova que a instalada.
@MainActor func announceUpdate(_ app: AppState) {
    let repo = RepoSync.shared
    guard repo.updateAvailable, let sha = repo.latestCode else { return }
    app.info("Nova versão do CellStudio no GitHub (\(sha.prefix(7)): \(repo.latestMessage ?? "")). "
             + (Platform.isMac ? "Atualize com git pull e ./build.sh." : "O Mac instala no iPhone quando ele estiver conectado."))
}

/// Linha de um robô ou arquivo 3D: baixar/atualizar e, depois de baixado, abrir/importar/usar.
struct DownloadRow: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var repo = RepoSync.shared
    @Environment(\.dismiss) private var dismiss
    let item: RemoteItem

    var body: some View {
        let status = repo.status(item)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: item.kind == .flash ? "externaldrive" : (item.isFolder ? "cube.transparent" : "car.side"))
                    .foregroundStyle(DXQ.blue).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.kind == .flash ? item.label : item.name).font(.system(size: 15, weight: .semibold))
                    if item.kind == .flash, item.label != item.name.split(separator: "/").last.map(String.init) {
                        Text(item.name.split(separator: "/").last.map(String.init) ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text("\(item.files.count) arquivo(s) · \(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let p = repo.progress[item.id] {
                    ProgressView(value: p).frame(width: 80)
                } else {
                    switch status {
                    case .missing: Button("Baixar") { Task { await download(item) } }.buttonStyle(.borderedProminent)
                    case .outdated: Button("Atualizar") { Task { await download(item) } }.buttonStyle(.bordered)
                    case .current: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
            }
            if status != .missing, repo.progress[item.id] == nil { actions(item) }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func actions(_ item: RemoteItem) -> some View {
        HStack(spacing: 10) {
            switch item.kind {
            case .flash:
                Button("Abrir na estação") { app.openBackup(item.localURL); close() }
            case .body where isModelLibrary(item):
                Button(app.modelsRoot?.standardizedFileURL == item.localURL.standardizedFileURL ? "Biblioteca de modelos em uso" : "Usar como modelos 3D") {
                    app.modelsRoot = item.localURL
                }
                .disabled(app.modelsRoot?.standardizedFileURL == item.localURL.standardizedFileURL)
            case .body:
                ForEach(partFiles(item), id: \.self) { url in
                    Button("Importar \(url.lastPathComponent)") { app.importPart(url, asBody: true); close() }
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    func download(_ item: RemoteItem) async {
        guard await repo.download(item) else { return }
        // biblioteca de modelos baixada e nenhuma em uso: passa a usar
        if item.kind == .body, isModelLibrary(item), app.modelsRoot == nil { app.modelsRoot = item.localURL }
    }

    private func isModelLibrary(_ item: RemoteItem) -> Bool {
        item.isFolder && item.files.contains { $0.path.hasPrefix(item.repoPath + "/Robots/") }
    }

    private func partFiles(_ item: RemoteItem) -> [URL] {
        let exts: Set<String> = ["hsf", "stl", "obj", "usdz", "usd", "ply"]
        guard item.isFolder else { return exts.contains(item.localURL.pathExtension.lowercased()) ? [item.localURL] : [] }
        return item.files.map { item.localURL.appendingPathComponent(String($0.path.dropFirst(item.repoPath.count + 1))) }
            .filter { exts.contains($0.pathExtension.lowercased()) }.prefix(6).map { $0 }
    }

    private func close() { if Platform.isMac { dismiss() } }
}

/// Um módulo de flash's (Avulso, VW A…): robôs agrupados por estação.
struct ModuleDownloadsView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var repo = RepoSync.shared
    let module: String

    var body: some View {
        let robots = repo.items.filter { $0.kind == .flash && $0.module == module }
        let stations = Array(Set(robots.map(\.station))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        List {
            ForEach(stations, id: \.self) { st in
                let list = robots.filter { $0.station == st }.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
                Section {
                    ForEach(list) { DownloadRow(item: $0) }
                } header: {
                    HStack {
                        Text(st.isEmpty ? "Robôs" : "Estação \(st)")
                        Spacer()
                        if list.count > 1 { stationButtons(list) }
                    }
                }
            }
        }
        .navigationTitle(module.isEmpty ? "Sem módulo" : module)
        .navigationBarTitleDisplayModeInline()
    }

    /// Baixar todos / abrir todos os robôs da estação de uma vez.
    @ViewBuilder private func stationButtons(_ list: [RemoteItem]) -> some View {
        let missing = list.filter { repo.status($0) != .current }
        if !missing.isEmpty {
            Button("Baixar todos") {
                Task { for r in missing { _ = await repo.download(r) } }
            }
            .disabled(list.contains { repo.progress[$0.id] != nil })
        } else {
            Button("Abrir todos") { list.forEach { app.openBackup($0.localURL) } }
        }
    }
}
