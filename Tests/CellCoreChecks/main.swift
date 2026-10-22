import CellCore
import Foundation
import simd

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    print(cond ? "✓ \(msg)" : "✗ \(msg)")
    if !cond { failures += 1 }
}

// Pose ↔ matriz
let p = Pose(x: 100, y: -50, z: 1200, a: 30, b: -45, c: 170)
let p2 = Pose(matrix: p.matrix)
check(simd_distance(p.matrix.position, p2.matrix.position) < 1e-9 && simd_length(p.matrix.rotation.columns.0 - p2.matrix.rotation.columns.0) < 1e-9, "Pose ABC ida e volta")

// Cinemática direta/inversa
let robot = RobotModel.demo
let home = JointState.home(for: robot)
let q = JointState(q: [20, -10, 15, 40, 50, -30])
let target = Pose(matrix: Kinematics.tcp(robot, q))
let ik = Kinematics.inverse(robot, target: target, seed: home)
let reached = Pose(matrix: Kinematics.tcp(robot, ik.state))
check(ik.converged, "IK converge (erro \(String(format: "%.4f", ik.positionError)) mm, \(String(format: "%.4f", ik.orientationError))°)")
check(simd_distance(reached.position, target.position) < 0.5, "IK atinge a posição")

// Catálogo
let catalogURL = URL(fileURLWithPath: "Sources/CellStudio/Resources/robots.json")
let catalog = try RobotCatalogEntry.loadCatalog(from: catalogURL)
check(catalog.count > 20, "Catálogo carregado (\(catalog.count) braços)")
for e in catalog.prefix(40) {
    let m = RobotModel(catalog: e)
    let t = Pose(matrix: Kinematics.tcp(m, JointState(q: [10, 5, -5, 20, 40, 10])))
    let r = Kinematics.inverse(m, target: t, seed: .home(for: m))
    if !r.converged { check(false, "IK \(e.name)") }
}
check(true, "IK em 40 tipos do catálogo")

// KRL
let src = """
DEF test( )
PTP {X 1500, Y 0, Z 1500, A 0, B 90, C 0}
$VEL.CP=0.4
$OUT[3]=TRUE
LIN XP2
$OUT[3]=FALSE
LIN XP3 C_DIS
END
"""
let dat = "DECL E6POS XP2={X 1600,Y 100,Z 1400,A 0,B 90,C 0,E1 250}\nDECL E6POS XP3={X 1700,Y 0,Z 1300,A 0,B 90,C 0,E1 0}"
let prog = KRL.parse(src: src, dat: dat)
check(prog.points.count == 3, "KRL: 3 movimentos")
check(prog.points[1].paintOn && !prog.points[2].paintOn, "KRL: gatilho de pintura")
check(prog.points[1].speed == 400 && prog.points[1].rail == 250, "KRL: velocidade e E1")
let exported = KRL.export(prog)
let back = KRL.parse(src: exported.src, dat: exported.dat).points
check(back.count == prog.points.count && zip(back, prog.points).allSatisfy { $0.pose == $1.pose && $0.motion == $1.motion && $0.speed == $1.speed && $0.paintOn == $1.paintOn && $0.rail == $1.rail }, "KRL: exportar e reimportar")

// Pintura: passada única sobre painel plano, centro deve receber mais tinta que as bordas
let plate = STL.demoPanel(width: 1000, depth: 1000, crown: 0, height: 0, resolution: 100)
let sim = PaintSimulator(mesh: plate)
let brush = Brush(id: 1, name: "t", flowRate: 300, coneHalfAngle: 15, beta: 2, transferEfficiency: 0.8, solids: 0.5)
var x = -400.0
while x <= 400 {
    sim.deposit(gun: Pose(x: x, y: 0, z: 250, b: 180).matrix, brush: brush, dt: 0.002)
    x += 1  // 500 mm/s com dt 2 ms
}
let center = plate.positions.indices.min { simd_length(plate.positions[$0] - SIMD3(0, 0, 0)) < simd_length(plate.positions[$1] - SIMD3(0, 0, 0)) }!
let side = plate.positions.indices.min { simd_length(plate.positions[$0] - SIMD3(0, 50, 0)) < simd_length(plate.positions[$1] - SIMD3(0, 50, 0)) }!
check(sim.thickness[center] > sim.thickness[side] && sim.thickness[side] > 0, "Perfil do leque: centro \(Int(sim.thickness[center])) µm > lateral \(Int(sim.thickness[side])) µm")
// Balanço de massa: volume depositado ≈ vazão × TE × sólidos × tempo (só a parte que cai na placa)
let cell: Float = 10 * 10
let deposited = sim.thickness.reduce(0, +) * cell / 1000  // mm³
let expected = Float(300.0 / 60 * 1000 * 0.8 * 0.5 * 1.6)
check(abs(deposited - expected) / expected < 0.1, "Balanço de massa: \(Int(deposited)) mm³ vs \(Int(expected)) mm³")

// Refinamento
let coarse = Mesh(positions: [SIMD3(0, 0, 0), SIMD3(1000, 0, 0), SIMD3(0, 1000, 0)], indices: [0, 1, 2])
let fine = coarse.refined(maxEdge: 50)
check(fine.indices.count / 3 > 400, "Refinamento: \(fine.indices.count / 3) triângulos")

// Trajetória
let zig = RobotProgram.zigzag(minX: 1200, maxX: 1800, minY: -300, maxY: 300, z: 600, standoff: 250, brush: brush)
let traj = Trajectory.sample(program: zig, robot: robot, start: home)
check(!traj.samples.isEmpty, "Trajetória: \(traj.samples.count) amostras, inalcançáveis: \(traj.unreachable)")

// Dados reais do controlador (se as pastas existirem)
let realRoots = ["../R11", "../R22"].map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
for root in realRoots {
    guard let bk = try? RobotBackup.load(root) else { check(false, "Backup \(root.lastPathComponent)"); continue }
    check(bk.robot.joints.count == 6 && bk.robot.railEnabled, "\(bk.robot.name): machinedata com 6 eixos + trilho, \(bk.projects.count) projetos")
    var dists: [Double] = []
    for proj in bk.projects {
        for prog in proj.programs {
            let pts = EcoTalkInterpreter(project: proj, systemData: bk.systemData, robot: bk.robot).run(prog.name).program.points
            for i in 0..<max(pts.count - 1, 0) where pts[i].joints != nil && pts[i + 1].joints == nil {
                var r = bk.robot; r.tool = pts[i + 1].tool ?? Pose()
                dists.append(simd_distance(Kinematics.tcp(r, JointState(rail: pts[i].rail, q: pts[i].joints!)).position, pts[i + 1].pose.position))
            }
        }
    }
    dists.sort()
    let med = dists.isEmpty ? .infinity : dists[dists.count / 2]
    check(med < 400, "\(bk.robot.name): pontos Axis e Object coerentes (mediana \(Int(med)) mm em \(dists.count) pares)")
}

// Segmentos não comprimidos entre blocos devem manter oculta a biblioteca de includes.
let toolURL = URL(fileURLWithPath: "../_analise/inst/3DObjects/Tools/Sealing/EcoGun2 3D/EcoGun2_3D_2ACV1_4580_L400.hsf")
if FileManager.default.fileExists(atPath: toolURL.path) {
    let tool = try HSF.load(toolURL)
    check(!tool.isEmpty && HSF.lastWarning == nil, "Pistola R22: múltiplos blocos zlib completos")
    check(tool.allSatisfy { $0.positions.allSatisfy { simd_length($0) < 2 } }, "Biblioteca da pistola não cria geometria fora da estação")
}

// Regressão HSF 23: CRCs e dois blocos zlib (a geometria está no segundo).
let bodyURL = URL(fileURLWithPath: "../SAGA_HEV_reduzido 2.hsf")
if FileManager.default.fileExists(atPath: bodyURL.path) {
    let body = try HSF.load(bodyURL)
    check(HSF.lastWarning == nil, "HSF 23 da carroceria lido integralmente")
    check(body.reduce(0) { $0 + $1.indices.count / 3 } == 3_698_876, "HSF preserva os 3.698.876 triângulos do segundo bloco zlib")
    let bounds = Mesh(positions: body.flatMap(\.positions), indices: body.flatMap(\.indices)).bounds
    check(abs(bounds.max.x - bounds.min.x - 4.0155) < 0.01, "Carroceria HSF com comprimento de aproximadamente 4,02 m")
}

// Regressão do hanger enviado pelo usuário: line styles/named patterns e refs
// em HSF 23 têm CRCs próprios antes da geometria do suporte.
let hangerURL = URL(fileURLWithPath: "../elefantesimples.hsf")
if FileManager.default.fileExists(atPath: hangerURL.path) {
    let hanger = try HSF.load(hangerURL)
    let triangles = hanger.reduce(0) { $0 + $1.indices.count / 3 }
    check(HSF.lastWarning == nil, "HSF 23 do hanger lido integralmente")
    check(!hanger.isEmpty && triangles > 100_000, "Hanger preserva a malha (\(triangles) triângulos)")
}

// EcoTalk: fluxo de controle e ações de sincronização
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ecotalk_test.tt")
    try? FileManager.default.removeItem(at: dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let tid = "P1 : POINT := (World, 1500, 0, 1500, 0, 90, 0, 0, 0, 0)\nP2 : POINT := (World, 1600, 0, 1500, 0, 90, 0, 0, 0, 0)\nP3 : POINT := (World, 1600, 100, 1500, 0, 90, 0, 0, 0, 0)\n"
    let tip = """
    RSELECT("RX")
      N := 0
      LOOP 3 DO
        LIN(P1)
        N := N + 1
      END_LOOP
      IF N = 3 THEN
        LIN(P2)
      ELSIF N = 2 THEN
        LIN(P3)
      ELSE
        LIN(P3)
      END_IF
      IF NOT GET_BOOL_SYSTEMVAR(PCUx, "SV_Release", High) THEN
        LIN(P3)
      END_IF
      SET(Collision1, High)
      RECEIVE(Collision1, High)
      DELAY(0.5)
      CIRC(P2, P3)
      GOTO FIM
      LIN(P1)
      LABEL FIM
      SET(Collision1, Low)
    RDESELECT("RX")
    """
    try tip.write(to: dir.appendingPathComponent("main.tip"), atomically: true, encoding: .isoLatin1)
    try tid.write(to: dir.appendingPathComponent("main.tid"), atomically: true, encoding: .isoLatin1)
    let res = EcoTalkInterpreter(project: EcoTalkProject.load(dir), systemData: [], robot: robot).run("main")
    let names = res.program.points.map(\.name)
    check(names == ["P1", "P1", "P1", "P2", "P3"], "EcoTalk: LOOP, IF/ELSIF, GOTO/LABEL (\(names.joined(separator: " ")))")
    check(res.program.points.last?.motion == .circ, "EcoTalk: CIRC com ponto intermediário")
    check(res.actions.map(\.kind) == [.set, .receive, .delay, .set], "EcoTalk: ações SET/RECEIVE/DELAY")
}

// Bits de colisão (regra do DXQ): dois robôs disputam Collision1
do {
    func fake(_ n: Int, _ pt: Int) -> [TrajectorySample] { (0..<n).map { TrajectorySample(time: Double($0 + 1) * 0.02, state: home, paintOn: false, brush: 1, pointIndex: pt) } }
    func act(_ k: EcoTalkSyncAction.Kind, _ high: Bool, _ after: Int) -> EcoTalkSyncAction {
        EcoTalkSyncAction(kind: k, pin: "Collision1", high: high, seconds: 0, afterPoint: after, program: "t", line: 0)
    }
    // A: pede a zona, entra (2 s dentro), libera. B: pede logo depois, precisa esperar A.
    let a = StationScheduler.Input(robot: "A", samples: fake(100, 0) + fake(10, 1), actions: [act(.set, true, 0), act(.receive, true, 0), act(.set, false, 1)], pointCount: 2, start: home)
    let b = StationScheduler.Input(robot: "B", samples: fake(5, 0) + fake(50, 1), actions: [act(.set, true, 1), act(.receive, true, 1), act(.set, false, 2)], pointCount: 2, start: home)
    let out = StationScheduler.run([a, b])
    let waitB = out.waitTime["B"] ?? 0
    check(waitB > 1.5 && (out.waitTime["A"] ?? 0) < 0.1, String(format: "Bits de colisão: B esperou %.2f s pela zona de A", waitB))
    check(!out.events.contains { $0.kind == .deadlock }, "Bits de colisão: sem impasse")
    let za = out.zones.filter { $0.owner == "A" }, zb = out.zones.filter { $0.owner == "B" }
    check(za.count == 1 && zb.count == 1 && zb[0].start >= za[0].end - 1e-9,
          String(format: "Bits de colisão: intervalos de zona A %.2f–%.2f, B %.2f–%.2f", za.first?.start ?? -1, za.first?.end ?? -1, zb.first?.start ?? -1, zb.first?.end ?? -1))
    check(out.waits.count == 1 && out.waits[0].robot == "B" && out.waits[0].blockedBy == "A", "Bits de colisão: espera de B registrada (bloqueado por A)")
    // impasse: cada um segura uma zona e espera a do outro
    func act2(_ k: EcoTalkSyncAction.Kind, _ pin: String, _ high: Bool) -> EcoTalkSyncAction {
        EcoTalkSyncAction(kind: k, pin: pin, high: high, seconds: 0, afterPoint: 1, program: "t", line: 0)
    }
    let c = StationScheduler.Input(robot: "C", samples: fake(3, 0), actions: [act2(.set, "Z1", true), act2(.receive, "Z1", true), act2(.set, "Z2", true), act2(.receive, "Z2", true)], pointCount: 1, start: home)
    let d = StationScheduler.Input(robot: "D", samples: fake(3, 0), actions: [act2(.set, "Z2", true), act2(.receive, "Z2", true), act2(.set, "Z1", true), act2(.receive, "Z1", true)], pointCount: 1, start: home)
    let dl = StationScheduler.run([c, d], deadlockAfter: 5)
    check(dl.events.contains { $0.kind == .deadlock }, "Bits de colisão: impasse detectado")
    check(dl.waits.contains { $0.forced }, "Bits de colisão: espera forçada registrada no impasse")
}

// system.ttu real (6010 R21) e operações do editor de programa
do {
    let ttu = URL(fileURLWithPath: "../6010/2026_10_07__04_19_20_6010_R21/application/control/teachcontrol/_system.tt/system.ttu")
    if let sys = EcoSystemDeclarations.load(ttu) {
        let gun = sys.routine("GUN")
        check(gun?.group == "PROCESS" && gun?.parameters.map(\.type) == ["GUNNO", "GUNONOFF", "POINT", "TRIGGERFRAME"], "system.ttu: GUN(GUNNO, GUNONOFF, POINT, TRIGGERFRAME) em PROCESS")
        check(sys.enums["IOTYPE"] == ["High", "Low", "Data"], "system.ttu: enum IOTYPE")
        check(sys.blocks["POINT"]?.prefix == "P" && sys.blocks["POINT"]?.fields.count == 10 && sys.blocks["POINT"]?.fields.first?.defaultValue == "Object", "system.ttu: BLOCK POINT (prefixo P, 10 campos, Coord := Object)")
        let groups = sys.insertGroups(showAll: false)
        check(groups.first?.group == "MOVEMENT" && groups.contains { $0.group == "Logic" && $0.commands.contains("IF") }, "system.ttu: grupos do menu Inserir (\(groups.count))")
        check(!(groups.first { $0.group == "MOVEMENT" }?.commands.contains("SPLINE") ?? true) && sys.insertGroups(showAll: true).contains { $0.commands.contains("SPLINE") },
              "system.ttu: comandos condicionais só com 'mostrar todos'")
    } else { print("  (system.ttu da 6010 não encontrado – teste pulado)") }

    var p = EcoTalkProgram(name: "T", url: URL(fileURLWithPath: "/tmp/T.tip"),
                           source: "RSELECT(\"R1\")\r\n  PTP(P1)\r\n  LIN(P2) // fim\r\nRDESELECT(\"R1\")\r\n",
                           data: "// POINT\r\nP1 : POINT := (Axis, 1, 2, 3, 4, 5, 6, 0, 0, 0)\r\nP2 : POINT := (Object, 10, 20, 30, 0, 0, 0, 0, 0, 0)\r\n")
    let ls = EcoProgramEditor.lines(p)
    check(ls[2].name == "LIN" && ls[2].args == ["P2"] && ls[2].trailingComment == "fim", "Editor: linha LIN(P2) // fim")
    let ind = EcoProgramEditor.indent(after: 0, in: p)
    EcoProgramEditor.insert(EcoProgramEditor.insertion(name: "IF", args: ["X > 1"], indent: ind), after: 0, in: &p)
    check(EcoProgramEditor.rawLines(p.source)[1] == "  IF X > 1 THEN" && EcoProgramEditor.rawLines(p.source)[2] == "  END_IF" && p.source.contains("\r\n"),
          "Editor: inserir IF com END_IF e indentação, mantendo CRLF")
    EcoProgramEditor.delete([1, 2], in: &p)
    EcoProgramEditor.setDisabled([1], true, in: &p)
    check(EcoProgramEditor.rawLines(p.source)[1] == "  ##PTP(P1)" && !EcoTalk.parseProgram(p.source).contains { $0.name.contains("PTP") }, "Editor: desativar (##) e o interpretador ignora")
    EcoProgramEditor.setDisabled([1], false, in: &p)
    EcoProgramEditor.commentOut([2], in: &p)
    check(EcoProgramEditor.rawLines(p.source)[2] == "  //LIN(P2) // fim", "Editor: transformar em comentário")
    EcoProgramEditor.commentIn([2], in: &p)
    check(EcoProgramEditor.rawLines(p.source)[2] == "  LIN(P2) // fim", "Editor: retirar comentário")
    EcoProgramEditor.reverse([1, 2], in: &p)
    check(EcoProgramEditor.lines(p)[1].name == "LIN" && EcoProgramEditor.lines(p)[2].name == "PTP", "Editor: inverter sentido do movimento")
    let free = EcoProgramEditor.nextFreeName(prefix: "P", taken: Set(p.declarations.map(\.name)))
    EcoProgramEditor.setDeclaration(name: free, type: "POINT", args: ["Object", "1.5", "0", "0", "0", "0", "0", "0", "0", "0"], in: &p)
    check(free == "P3" && p.declarations.last?.name == "P3" && EcoProgramEditor.rawLines(p.data)[3] == "P3 : POINT := (Object, 1.5, 0, 0, 0, 0, 0, 0, 0, 0)", "Editor: novo ponto P3 no fim da seção POINT")
    EcoProgramEditor.insert(["  PTP(P3)"], after: 2, in: &p)
    let plan = EcoProgramEditor.reindexPoints([1, 2, 3], prefix: "P", start: 1, in: &p)
    check(plan.count == 2 && EcoProgramEditor.lines(p)[1].args == ["P1"] && EcoProgramEditor.lines(p)[2].args == ["P2"] && EcoProgramEditor.lines(p)[3].args == ["P3"]
          && p.declarations.first { $0.name == "P1" }?.args.first == "Object", "Editor: reindexar pontos (LIN(P2)→P1, PTP(P1)→P2)")
}

// Erros de cinemática (CheckJointLimits do DXQ + códigos do MCU)
do {
    var s350 = JointState(q: [350, 0, 0, 0, 30, 0])
    let fix = JointLimits.check(&s350, robot: robot, tryToFix: true)
    check(fix.0 == .ok && abs(s350.q[0] + 10) < 1e-9, "Limites: correção ±360° (350° → -10°) como o tryToFix do DXQ")
    var sBad = JointState(q: [0, 0, 0, 0, robot.joints[4].max + 15, 0])
    let bad = JointLimits.check(&sBad, robot: robot)
    check(bad.0 == .error && bad.1.first?.name == robot.joints[4].name && abs(bad.1[0].excess - 15) < 1e-9, "Limites: A5 15° além do máximo → erro")

    var axisPt = ProgramPoint(name: "PX", motion: .ptp, pose: Pose(), speed: 100)
    axisPt.joints = [0, 0, 0, 0, robot.joints[4].max + 15, 0]
    let r1 = Trajectory.sample(program: RobotProgram(name: "t", points: [axisPt]), robot: robot, start: home)
    check(r1.issues.contains { $0.code == 536 && $0.kind == .jointLimit } && r1.unreachable == [0], "Ponto Axis fora do limite → MCU 536")

    let far = ProgramPoint(name: "PFAR", motion: .ptp, pose: Pose(x: 20000, y: 0, z: 1000, b: 180), speed: 100)
    let r2 = Trajectory.sample(program: RobotProgram(name: "t", points: [far]), robot: robot, start: home)
    check(r2.issues.contains { $0.code == 571 }, "Ponto longe demais → MCU 571 (posição não alcançável): \(r2.issues.first?.text ?? "-")")

    // alcançável, mas só com A1 fora de uma faixa estreita
    var narrow = robot
    narrow.joints[0].min = -10; narrow.joints[0].max = 10
    let side = Pose(matrix: Kinematics.tcp(robot, JointState(q: [90, 0, 10, 0, 40, 0])))
    let r3 = Trajectory.sample(program: RobotProgram(name: "t", points: [ProgramPoint(name: "PSIDE", motion: .ptp, pose: side, speed: 100)]), robot: narrow, start: home)
    check(r3.issues.contains { $0.code == 536 && $0.text.contains(narrow.joints[0].name) }, "Alcançável só além do limite de A1 → MCU 536: \(r3.issues.first?.text ?? "-")")

    // trajetória normal sem erros
    check(traj.unreachable.isEmpty || !Trajectory.sample(program: zig, robot: robot, start: home).issues.isEmpty, "Zigue-zague: inalcançáveis coerentes com os erros")

    // avisos configuráveis (desligados por padrão)
    var w = SimulationWarningSettings()
    let nearMax = JointState(q: [robot.joints[0].max - 2, 0, 0, 0, 0.5, 0])
    check(JointLimits.warnings(nearMax, robot: robot, settings: w).isEmpty, "Avisos desligados por padrão (como no DXQ)")
    w.enableJointLimitWarnings = true; w.jointWarningMax = [5, 5, 5, 5, 5, 5]; w.singularityWarningLimit = 1
    let ws = JointLimits.warnings(nearMax, robot: robot, settings: w)
    check(ws.count == 2 && ws.contains { $0.contains("singularidade") }, "Avisos: margem do eixo e singularidade |A5| ≤ 1°")
}

// Aplicar sugestões (texto)
do {
    var p = EcoTalkProgram(name: "A", url: URL(fileURLWithPath: "/tmp/A.tip"),
        source: "  LIN( P1 )\r\n  GUN( GUN1 ,GunOn ,PT1 ,TR1 )\r\n  LIN( P2 )\r\n  LIN( P3 )\r\n  GUN( GUN1 ,GunOff ,PT2 ,TR2 )\r\n  LIN( P4 )\r\n  LIN( P5 )\r\n", data: "")
    // inversão da passada P1→P4 como a análise gera: LIN(P4) GUN(on,PT2) LIN(P3) LIN(P2) GUN(off,PT1) LIN(P1)
    let rev = ["LIN( P4 )", "GUN( GUN1 ,GunOn ,PT2 ,TR2 )", "LIN( P3 )", "LIN( P2 )", "GUN( GUN1 ,GunOff ,PT1 ,TR1 )", "LIN( P1 )"]
    EcoProgramEditor.apply(rev.enumerated().map { SourceEdit(robot: "R", program: "A", line: $0.offset + 1, op: .replace("  " + $0.element)) }, to: &p)
    check(EcoProgramEditor.rawLines(p.source).map { $0.trimmingCharacters(in: .whitespaces) } == rev + ["LIN( P5 )"], "Aplicar: passada invertida com disparos trocados")
    EcoProgramEditor.apply([SourceEdit(robot: "R", program: "A", line: 1, op: .insertBefore(["  SET( Collision3 ,High )", "  RECEIVE( Collision3 ,High )"])),
                            SourceEdit(robot: "R", program: "A", line: 6, op: .insertAfter(["  SET( Collision3 ,Low )"])),
                            SourceEdit(robot: "R", program: "A", line: 7, op: .disable)], to: &p)
    let l = EcoProgramEditor.rawLines(p.source).map { $0.trimmingCharacters(in: .whitespaces) }
    check(l.first == "SET( Collision3 ,High )" && l[1] == "RECEIVE( Collision3 ,High )" && l[8] == "SET( Collision3 ,Low )" && l[9] == "##LIN( P5 )" && p.source.contains("\r\n"),
          "Aplicar: bit antes/depois e ponto desativado, linhas sem deslocar: \(l)")
}

// Edição de pontos (guia Transformation do DXQ)
do {
    var tool = robot; tool.tool = Pose(z: 250)
    let obj = Pose(x: 1500, y: -300, z: 200, c: 90)
    let ctx = PointContext(robot: tool, object: obj, seed: JointState(q: [20, -10, 15, 40, 50, -30]))
    let w0 = Kinematics.tcp(tool, ctx.seed)
    let lp = Pose(matrix: obj.matrix.inverse * w0)
    let objPt = PointRecord(mode: "Object", values: [lp.x, lp.y, lp.z, lp.a, lp.b, lp.c], rail: 0, extra: ["0", "0"])
    check(PointRecord(args: objPt.args) == PointRecord(args: objPt.args) && PointRecord(args: objPt.args)?.extra == ["0", "0"], "POINT .tid ida e volta")
    func near(_ a: Mat4, _ b: Mat4, _ tol: Double = 0.01) -> Bool {
        simd_distance(a.position, b.position) < tol && simd_length(a.zAxis - b.zAxis) < 1e-3 && simd_length(a.xAxis - b.xAxis) < 1e-3
    }
    // Mundo: +10 em X do mundo, orientação igual
    if case .success(let r) = PointTransform.shift(objPt, by: PointOffset(pose: Pose(x: 10)), in: .world, ctx) {
        let w = PointTransform.world(r, ctx)
        check(r.mode == "Object" && simd_distance(w.position, w0.position + Vec3(10, 0, 0)) < 0.01 && simd_length(w.zAxis - w0.zAxis) < 1e-6, "Deslocar em Mundo mantém tipo Object e move X do mundo")
    } else { check(false, "Deslocar em Mundo") }
    // Objeto: +10 em X do objeto (girado 90° → Y do mundo)
    if case .success(let r) = PointTransform.shift(objPt, by: PointOffset(pose: Pose(x: 10)), in: .object, ctx) {
        check(simd_distance(PointTransform.world(r, ctx).position, w0.position + Vec3(0, 10, 0)) < 0.01, "Deslocar em Objeto segue os eixos do objeto")
    } else { check(false, "Deslocar em Objeto") }
    // Ferramenta: +10 em Z da ferramenta = ao longo do jato
    if case .success(let r) = PointTransform.shift(objPt, by: PointOffset(pose: Pose(z: 10)), in: .tool, ctx) {
        check(simd_distance(PointTransform.world(r, ctx).position, w0.position + simd_normalize(w0.zAxis) * 10) < 0.01, "Deslocar em Ferramenta anda na direção Z da pistola")
    } else { check(false, "Deslocar em Ferramenta") }
    // Girar em Mundo em torno de Z: posição fica, orientação gira
    if case .success(let r) = PointTransform.shift(objPt, by: PointOffset(pose: Pose(c: 90)), in: .world, ctx) {
        let w = PointTransform.world(r, ctx)
        let expected = Mat4.rotZ(rad(90)) * w0
        check(simd_distance(w.position, w0.position) < 0.01 && simd_length(w.zAxis - expected.zAxis) < 1e-6, "Girar C em Mundo gira no próprio ponto")
    } else { check(false, "Girar em Mundo") }
    // Eixos num ponto Axis: soma direta
    let axisPt = PointRecord(mode: "Axis", values: ctx.seed.q, rail: 0, extra: ["0", "0"])
    if case .success(let r) = PointTransform.shift(axisPt, by: PointOffset(joints: [5, 0, 0, 0, 0, 0]), in: .joint, ctx) {
        check(abs(r.values[0] - 25) < 1e-9 && r.values[1...] == axisPt.values[1...], "Deslocar A1 em Eixos num ponto Axis")
    } else { check(false, "Deslocar em Eixos") }
    // Ponto Axis deslocado em Mundo continua Axis e o TCP anda
    if case .success(let r) = PointTransform.shift(axisPt, by: PointOffset(pose: Pose(z: -20)), in: .world, ctx) {
        check(r.mode == "Axis" && near(PointTransform.world(r, ctx), Mat4.translation(Vec3(0, 0, -20)) * w0, 0.5), "Ponto Axis deslocado em Mundo pela inversa")
    } else { check(false, "Ponto Axis em Mundo") }
    // Converter Object → World → Axis → Object sem mexer no TCP
    if case .success(let a) = PointTransform.convert(objPt, to: "World", ctx), case .success(let b) = PointTransform.convert(a, to: "Axis", ctx),
       case .success(let c) = PointTransform.convert(b, to: "Object", ctx) {
        check(a.mode == "World" && b.mode == "Axis" && near(PointTransform.world(c, ctx), w0, 0.5), "Converter tipo do ponto mantém o TCP")
    } else { check(false, "Converter tipo") }
    // Girar 180° em torno de um vetor e espelhar duas vezes voltam ao lugar
    let s0 = Vec3(lp.x + 100, lp.y, 0)
    if case .success(let r1) = PointTransform.rotate(objPt, start: s0, end: s0 + Vec3(0, 0, 1), angle: 180, ctx),
       case .success(let r2) = PointTransform.rotate(r1, start: s0, end: s0 + Vec3(0, 0, 1), angle: 180, ctx) {
        let l1 = PointTransform.world(r1, ctx)
        check(simd_distance((obj.matrix.inverse * l1).position, Vec3(lp.x + 200, lp.y, lp.z)) < 0.01 && near(PointTransform.world(r2, ctx), w0), "Girar em torno de vetor")
    } else { check(false, "Girar em torno de vetor") }
    if case .success(let m1) = PointTransform.mirror(objPt, plane: .xz, offset: 0, ctx), case .success(let m2) = PointTransform.mirror(m1, plane: .xz, offset: 0, ctx) {
        let l1 = obj.matrix.inverse * PointTransform.world(m1, ctx)
        let r = l1.rotation
        check(abs(l1.position.y + lp.y) < 0.01 && abs(r.determinant - 1) < 1e-9 && near(PointTransform.world(m2, ctx), w0), "Espelhar no plano XZ (Y → −Y, ferramenta destra)")
    } else { check(false, "Espelhar") }
    check(PointTransform.mirror(axisPt, plane: .xy, offset: 0, ctx) == .failure(.axisNotSupported), "Espelhar ponto Axis não é permitido (como no DXQ)")
}

// Ferramentas do editor: Objeto-Objeto, Ferramenta-Ferramenta, posição zero, suavizar, STL
do {
    let oldObj = Pose(x: 1000, y: 200, z: 0, c: 30), newObj = Pose(x: 900, y: -100, z: 50, c: -10)
    let pt = PointRecord(mode: "Object", values: [100, 50, 300, 170, 10, 20], rail: 0, extra: ["0", "0"])
    let w0 = oldObj.matrix * pt.pose.matrix
    if let r = PointTransform.changeObject(pt, from: oldObj, to: newObj) {
        let w1 = newObj.matrix * r.pose.matrix
        check(simd_distance(w0.position, w1.position) < 0.01 && simd_length(w0.zAxis - w1.zAxis) < 1e-6, "Objeto-Objeto mantém o ponto no mundo")
    } else { check(false, "Objeto-Objeto") }
    let oldTool = Pose(z: 250), newTool = Pose(x: 10, z: 300, b: 15)
    if let r = PointTransform.changeTool(pt, from: oldTool, to: newTool) {
        let f0 = pt.pose.matrix * oldTool.matrix.inverse, f1 = r.pose.matrix * newTool.matrix.inverse
        check(simd_distance(f0.position, f1.position) < 0.01 && simd_length(f0.zAxis - f1.zAxis) < 1e-6, "Ferramenta-Ferramenta mantém a flange")
    } else { check(false, "Ferramenta-Ferramenta") }
    let d = Pose(x: 5, y: -3, z: 2)
    check(PointTransform.correctZero(pt, delta: d).map { abs($0.values[0] - 105) < 1e-6 && abs($0.values[1] - 47) < 1e-6 } ?? false, "Correção da posição zero desloca pontos Object")
    let poses = [Pose(x: 0, a: 0), Pose(x: 100, a: 37), Pose(x: 300, a: -12), Pose(x: 400, a: 40)]
    let sm = PointTransform.smoothOrientations(poses)
    check(abs(sm[1].a - 10) < 1e-6 && abs(sm[2].a - 30) < 1e-6 && sm[0] == poses[0] && sm[3] == poses[3] && sm[1].x == 100, "Suavizar orientação interpola pela distância")
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cellstudio-test.stl")
    try? STL.writeBinary([(positions: [[0, 0, 0], [10, 0, 0], [0, 10, 0]], indices: [0, 1, 2])], to: url)
    check(((try? Data(contentsOf: url))?.count ?? 0) == 84 + 50, "STL binário com 1 triângulo")
}

print(failures == 0 ? "\nTODOS OS TESTES PASSARAM" : "\n\(failures) FALHA(S)")
exit(failures == 0 ? 0 : 1)
