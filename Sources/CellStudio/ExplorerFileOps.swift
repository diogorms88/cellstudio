import CellCore
import Foundation

/// Menus do explorador de projeto do DXQ (DirObjects / CleanupControl): projetos e programas de teach no disco.
/// Excluir manda para a Lixeira (dá para recuperar); depois de cada operação o backup do robô é relido.
extension AppState {
    func slot(_ id: UUID) -> RobotSlot? { robots.first { $0.id == id } }

    /// Pasta kin1/ onde ficam os projetos <nome>.tt do robô.
    func teachDir(_ robot: UUID) -> URL? {
        guard let bk = slot(robot)?.backup else { return nil }
        return bk.kinDir ?? bk.projects.first?.url.deletingLastPathComponent()
    }

    func promptText(_ title: String, message: String, value: String = "", ok: String = "OK") -> String? {
        Dialogs.prompt(title, message, value: value, ok: ok)
    }

    func confirm(_ title: String, _ message: String, ok: String) -> Bool {
        Dialogs.confirm(title, message, ok: ok)
    }

    private func latin1(_ s: String, _ url: URL) throws { try s.write(to: url, atomically: true, encoding: .isoLatin1) }

    /// Fecha as abas dos arquivos dentro de `url` (pergunta se houver alteração). false = o usuário cancelou.
    func closeTabs(under url: URL) -> Bool {
        for t in openTabs where t.id.path.hasPrefix(url.path) { closeTab(t.id) }
        return !openTabs.contains { $0.id.path.hasPrefix(url.path) }
    }

    private func pair(_ tip: URL) -> [URL] {
        [tip, tip.deletingPathExtension().appendingPathExtension("tid")].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: Pasta "Programas de teach"

    func addTeachProject(robot: UUID) {
        guard let dir = teachDir(robot), let name = promptText("Adicionar projeto de teach", message: "Nome do projeto") else { return }
        let url = dir.appendingPathComponent(name).appendingPathExtension("tt")
        guard !FileManager.default.fileExists(atPath: url.path) else { warn("Projeto \(name) já existe"); return }
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try latin1("", url.appendingPathComponent("_GlobalVars.tid"))
        } catch { self.error("Adicionar projeto: \(error.localizedDescription)"); return }
        refreshBackup(robot)
        info("Projeto de teach \(name) criado em \(slot(robot)?.name ?? "")")
    }

    func exportTeachProjects(robot: UUID, only project: URL? = nil) {
        guard let bk = slot(robot)?.backup else { return }
        guard let dest = Dialogs.chooseFolders(project == nil ? "Pasta de destino dos projetos de teach" : "Pasta de destino do projeto",
                                               prompt: "Exportar").first else { return }
        let list = project.map { [$0] } ?? bk.projects.map(\.url)
        var done = 0
        for src in list {
            let to = dest.appendingPathComponent(src.lastPathComponent)
            if FileManager.default.fileExists(atPath: to.path) {
                guard confirm("Substituir \(to.lastPathComponent)?", "Já existe em \(dest.path). A pasta atual vai para a Lixeira.", ok: "Substituir") else { continue }
                try? FileManager.default.discard(to)
            }
            if (try? FileManager.default.copyItem(at: src, to: to)) != nil { done += 1 }
        }
        info("\(done) projeto(s) de teach exportado(s) para \(dest.path)")
    }

    func importTeachProjects(robot: UUID) {
        guard let dir = teachDir(robot) else { return }
        let picked = Dialogs.chooseFolders("Escolha as pastas dos projetos de teach (.tt)", multiple: true, prompt: "Importar")
        guard !picked.isEmpty else { return }
        var done = 0
        for src in picked {
            let name = src.pathExtension.lowercased() == "tt" ? src.lastPathComponent : src.lastPathComponent + ".tt"
            let to = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: to.path) {
                guard confirm("Substituir \(name)?", "O projeto já existe neste robô. O atual vai para a Lixeira.", ok: "Substituir"), closeTabs(under: to) else { continue }
                try? FileManager.default.discard(to)
            }
            if (try? FileManager.default.copyItem(at: src, to: to)) != nil { done += 1 }
        }
        refreshBackup(robot)
        info("\(done) projeto(s) de teach importado(s) em \(slot(robot)?.name ?? "")")
    }

    /// Programas que nenhum Main nem tipo do typelist.ini alcança (seguindo os CALLs dentro do projeto).
    func unusedPrograms(robot: UUID) -> [EcoTalkProgram] {
        guard let bk = slot(robot)?.backup else { return [] }
        var used = Set<URL>()
        for proj in bk.projects {
            var queue = proj.programs.filter { $0.name.caseInsensitiveCompare("Main") == .orderedSame }
            for e in bk.typeList where e.project.caseInsensitiveCompare(proj.name) == .orderedSame {
                queue += proj.programs.filter { $0.name.caseInsensitiveCompare(e.program) == .orderedSame }
            }
            while let g = queue.popLast() {
                guard used.insert(g.url).inserted else { continue }
                for l in EcoProgramEditor.lines(g) where l.kind == .command && l.name == "CALL" {
                    if let callee = proj.programs.first(where: { $0.name.caseInsensitiveCompare(l.args.first ?? "") == .orderedSame }) { queue.append(callee) }
                }
            }
        }
        return bk.projects.flatMap(\.programs).filter { !used.contains($0.url) }
    }

    func trashPrograms(_ urls: [URL], robot: UUID) {
        var done = 0
        for u in urls {
            guard closeTabs(under: u) else { continue }
            for f in pair(u) { if (try? FileManager.default.discard(f)) != nil, f == u { done += 1 } }
        }
        refreshBackup(robot)
        info("\(done) programa(s) de teach enviados para a Lixeira")
    }

    // MARK: Projeto de teach

    func project(_ url: URL, robot: UUID) -> EcoTalkProject? { slot(robot)?.backup?.projects.first { $0.url == url } }

    func openAllPrograms(project url: URL, robot: UUID) {
        guard let proj = project(url, robot: robot) else { return }
        for g in proj.programs { showTab(g, robot: robot) }
        if let first = proj.programs.first { showTab(openTabs.first { $0.id == first.url }?.program ?? first, robot: robot) }
        info("\(proj.programs.count) programas de \(proj.name) abertos")
    }

    func closeAllPrograms(project url: URL? = nil) {
        for t in openTabs where url == nil || t.id.path.hasPrefix(url!.path) { closeTab(t.id) }
    }

    func checkPrograms(project url: URL, robot: UUID) {
        guard let proj = project(url, robot: robot), let s = slot(robot) else { return }
        checkPrograms(proj.programs, project: proj, robot: s)
    }

    func addTeachProgram(project url: URL, robot: UUID) {
        guard let name = promptText("Adicionar programa de teach", message: "Nome do programa") else { return }
        let tip = url.appendingPathComponent(name).appendingPathExtension("tip")
        guard !FileManager.default.fileExists(atPath: tip.path) else { warn("Programa \(name) já existe"); return }
        let r = slot(robot)?.name ?? "R1"
        do {
            try latin1("RSELECT(\"\(r)\")\r\n  //\r\nRDESELECT(\"\(r)\")\r\n", tip)
            try latin1("", tip.deletingPathExtension().appendingPathExtension("tid"))
        } catch { self.error("Adicionar programa: \(error.localizedDescription)"); return }
        refreshBackup(robot)
        if let g = project(url, robot: robot)?.programs.first(where: { $0.url == tip }) { showTab(g, robot: robot) }
        info("Programa \(name) criado")
    }

    func importTeachPrograms(project url: URL, robot: UUID) {
        let picked = Dialogs.chooseFiles([], multiple: true, message: "Escolha os programas (.tip; o .tid de mesmo nome vem junto)")
        guard !picked.isEmpty else { return }
        var done = 0
        for src in picked where src.pathExtension.lowercased() == "tip" {
            let to = url.appendingPathComponent(src.lastPathComponent)
            if FileManager.default.fileExists(atPath: to.path) {
                guard confirm("Substituir \(src.deletingPathExtension().lastPathComponent)?", "O programa já existe no projeto. O atual vai para a Lixeira.", ok: "Substituir"),
                      closeTabs(under: to) else { continue }
                for f in pair(to) { try? FileManager.default.discard(f) }
            }
            for f in pair(src) { try? FileManager.default.copyItem(at: f, to: url.appendingPathComponent(f.lastPathComponent)) }
            done += 1
        }
        refreshBackup(robot)
        info("\(done) programa(s) importado(s)")
    }

    /// Renomear programa (.tip/.tid) ou projeto (pasta .tt).
    func renameItem(_ url: URL, robot: UUID, to newName: String) {
        let isProject = url.pathExtension.lowercased() == "tt"
        guard closeTabs(under: url) else { return }
        let dest = url.deletingLastPathComponent().appendingPathComponent(newName).appendingPathExtension(isProject ? "tt" : "tip")
        guard !FileManager.default.fileExists(atPath: dest.path) else { warn("\(newName) já existe"); return }
        do {
            if isProject {
                try FileManager.default.moveItem(at: url, to: dest)
            } else {
                for f in pair(url) { try FileManager.default.moveItem(at: f, to: dest.deletingPathExtension().appendingPathExtension(f.pathExtension)) }
            }
        } catch { self.error("Renomear: \(error.localizedDescription)"); return }
        refreshBackup(robot)
        info("\(url.deletingPathExtension().lastPathComponent) renomeado para \(newName)" + (isProject ? "" : " (os CALLs que usam o nome antigo não mudam)"))
    }

    func promptRename(_ url: URL, robot: UUID) {
        let old = url.deletingPathExtension().lastPathComponent
        guard let n = promptText("Renomear", message: "Novo nome de \(old)", value: old, ok: "Renomear"), n != old else { return }
        renameItem(url, robot: robot, to: n)
    }

    /// "Substituir texto no nome": troca um texto no nome de todos os programas do projeto.
    func replaceTextInNames(project url: URL, robot: UUID, find: String, with repl: String) {
        guard !find.isEmpty, let proj = project(url, robot: robot) else { return }
        var n = 0
        for g in proj.programs where g.name.contains(find) {
            let newName = g.name.replacingOccurrences(of: find, with: repl)
            guard closeTabs(under: g.url) else { continue }
            let dest = url.appendingPathComponent(newName).appendingPathExtension("tip")
            guard !FileManager.default.fileExists(atPath: dest.path) else { warn("\(newName) já existe – \(g.name) não renomeado"); continue }
            for f in pair(g.url) { try? FileManager.default.moveItem(at: f, to: dest.deletingPathExtension().appendingPathExtension(f.pathExtension)) }
            n += 1
        }
        refreshBackup(robot)
        info("Substituir \"\(find)\" por \"\(repl)\": \(n) programa(s) renomeado(s)")
    }

    func deleteItem(_ url: URL, robot: UUID) {
        let isProject = url.pathExtension.lowercased() == "tt"
        let name = url.deletingPathExtension().lastPathComponent
        guard confirm("Excluir \(isProject ? "o projeto" : "o programa") \(name)?",
                      "Os arquivos vão para a Lixeira do Mac (dá para recuperar).", ok: "Excluir"),
              closeTabs(under: url) else { return }
        if isProject { try? FileManager.default.discard(url) }
        else { for f in pair(url) { try? FileManager.default.discard(f) } }
        refreshBackup(robot)
        info("\(name) enviado para a Lixeira")
    }

    // MARK: Recortar / copiar / colar

    func explorerCopy(_ url: URL, robot: UUID, cut: Bool) {
        explorerClipboard = (url, robot, cut)
        info("\(url.deletingPathExtension().lastPathComponent) \(cut ? "recortado" : "copiado")")
    }

    /// Cola um programa num projeto, ou um projeto na pasta de programas de teach do robô.
    func explorerPaste(into dir: URL, robot: UUID) {
        guard let c = explorerClipboard else { return }
        let isProject = c.url.pathExtension.lowercased() == "tt"
        var name = c.url.deletingPathExtension().lastPathComponent
        let ext = isProject ? "tt" : "tip"
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).appendingPathExtension(ext).path) {
            guard let n = promptText("\(name) já existe", message: "Nome para colar", value: name + "_Copia", ok: "Colar") else { return }
            name = n
        }
        let dest = dir.appendingPathComponent(name).appendingPathExtension(ext)
        do {
            if c.cut { guard closeTabs(under: c.url) else { return } }
            if isProject {
                if c.cut { try FileManager.default.moveItem(at: c.url, to: dest) } else { try FileManager.default.copyItem(at: c.url, to: dest) }
            } else {
                for f in pair(c.url) {
                    let to = dest.deletingPathExtension().appendingPathExtension(f.pathExtension)
                    if c.cut { try FileManager.default.moveItem(at: f, to: to) } else { try FileManager.default.copyItem(at: f, to: to) }
                }
            }
        } catch { self.error("Colar: \(error.localizedDescription)"); return }
        if c.cut { explorerClipboard = nil; if c.robot != robot { refreshBackup(c.robot) } }
        refreshBackup(robot)
        info("\(name) colado em \(dir.deletingPathExtension().lastPathComponent)")
    }

    // MARK: Comparador

    /// Diferença linha a linha (código e dados) entre dois programas.
    static func diff(_ a: String, _ b: String) -> [(kind: Character, text: String)] {
        let la = EcoProgramEditor.rawLines(a), lb = EcoProgramEditor.rawLines(b)
        let d = lb.difference(from: la)
        var removed = Set<Int>(), inserted = Set<Int>()
        for c in d {
            switch c {
            case .remove(let o, _, _): removed.insert(o)
            case .insert(let o, _, _): inserted.insert(o)
            }
        }
        var out: [(Character, String)] = []
        var i = 0, j = 0
        while i < la.count || j < lb.count {
            if i < la.count, removed.contains(i) { out.append(("-", la[i])); i += 1; continue }
            if j < lb.count, inserted.contains(j) { out.append(("+", lb[j])); j += 1; continue }
            if i < la.count { out.append((" ", la[i])) }
            i += 1; j += 1
        }
        return out
    }
}
