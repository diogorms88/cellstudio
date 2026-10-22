#if os(macOS)
import AppKit
#else
import UIKit
#endif
import CellCore
import SceneKit
import simd

/// Tipo dos componentes de SCNVector3: CGFloat no Mac, Float no iOS.
#if os(macOS)
typealias SCNFloat = CGFloat
#else
typealias SCNFloat = Float
#endif

/// Monta e atualiza a cena 3D. O nó `world` usa mm e Z para cima (como a estação do robô);
/// o SceneKit usa metros e Y para cima, então `world` é girado e escalado uma vez só.
final class SceneController {
    let scene = SCNScene()
    let world = SCNNode()
    let pathNode = SCNNode()
    let gridNode = SCNNode()
    let framesNode = SCNNode()
    let cameraNode = SCNNode()
    weak var view: SCNView?
    var cameraHistory: [simd_float4x4] = []
    var cameraHistoryIndex = -1
    var homeView: simd_float4x4?
    var floorNode: SCNNode?
    /// Mostrar/ocultar pontos, gatilhos (trechos com pistola ligada) e cones de direção do caminho
    var pathLayers = (points: true, triggers: true, cones: true) {
        didSet {
            for n in pathNode.childNodes {
                switch n.name {
                case "pt": n.isHidden = !pathLayers.points
                case "gun": n.isHidden = !pathLayers.triggers
                case "dir": n.isHidden = !pathLayers.cones
                default: break
                }
            }
        }
    }
    var measureNode: SCNNode?

    private final class RobotVisual {
        let root = SCNNode()
        var jointNodes: [SCNNode] = []
        var linkNodes: [(SCNNode, SCNNode)] = []
        let rail = SCNNode()
        let tool = SCNNode()
        let spray = SCNNode()
        let label = SCNNode()
        var size: Double = 100
        var tool6 = Pose()
        var models: [SCNNode?] = []      // malhas reais K1…K7 (DXQ .hsf), quando carregadas
        var modelKey = ""
        var railModel: SCNNode?          // trilho fixo
        var sledModel: SCNNode?          // carro (anda com E1)
        var partModels: [Int: SCNNode] = [:]
        var toolModel: SCNNode?
        var rootOffset: Double = 0
    }
    private var robots: [UUID: RobotVisual] = [:]
    private var partNodes: [UUID: SCNNode] = [:]
    private var partGeometry: [UUID: (positions: SCNGeometrySource, normals: SCNGeometrySource, element: SCNGeometryElement, count: Int)] = [:]

    // cores do DXQ: robô cinza-escuro metálico, partes claras
    private static func material(_ color: PlatformColor, metal: Double = 0.3, rough: Double = 0.45) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.lightingModel = .physicallyBased
        m.metalness.contents = metal
        m.roughness.contents = rough
        return m
    }
    private let armMaterial = material(PlatformColor(calibratedWhite: 0.32, alpha: 1))
    private let jointMaterial = material(PlatformColor(calibratedWhite: 0.20, alpha: 1))
    private let baseMaterial = material(PlatformColor(calibratedWhite: 0.88, alpha: 1), metal: 0.1)
    private let activeMaterial = material(PlatformColor(calibratedRed: 0.95, green: 0.55, blue: 0.10, alpha: 1), metal: 0.2)

    init() {
        world.eulerAngles.x = -.pi / 2
        world.scale = SCNVector3(0.001, 0.001, 0.001)
        scene.rootNode.addChildNode(world)
        world.addChildNode(pathNode)
        world.addChildNode(gridNode)
        world.addChildNode(framesNode)
        buildGrid()
        gridNode.isHidden = true          // o DXQ não mostra grade (só o chão opcional)
        scene.background.contents = Self.gradientImage()

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.intensity = 450
        scene.rootNode.addChildNode(ambient)
        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light!.type = .directional
        sun.light!.intensity = 1000
        sun.eulerAngles = SCNVector3(-1.0, 0.6, 0)
        scene.rootNode.addChildNode(sun)
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light!.type = .directional
        fill.light!.intensity = 450
        fill.eulerAngles = SCNVector3(-0.4, -2.4, 0)
        scene.rootNode.addChildNode(fill)

        cameraNode.camera = SCNCamera()
        cameraNode.camera!.zNear = 0.05
        cameraNode.camera!.zFar = 300
        cameraNode.camera!.fieldOfView = 40
        cameraNode.position = SCNVector3(6.0, 4.5, 6.0)
        cameraNode.look(at: SCNVector3(0, 1, 0))
        scene.rootNode.addChildNode(cameraNode)
    }

    /// Fundo da Vista 3D do DXQ (WindowBackgroundColor): degradê de (96,128,255) em cima para branco embaixo.
    static func gradientImage() -> PlatformImage {
        #if os(macOS)
        let size = NSSize(width: 8, height: 512)
        let img = NSImage(size: size)
        img.lockFocus()
        let g = NSGradient(colors: [NSColor(calibratedRed: 96 / 255, green: 128 / 255, blue: 1, alpha: 1), NSColor.white])!
        g.draw(in: NSRect(origin: .zero, size: size), angle: -90)
        img.unlockFocus()
        return img
        #else
        let size = CGSize(width: 8, height: 512)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor(red: 96 / 255, green: 128 / 255, blue: 1, alpha: 1).cgColor, UIColor.white.cgColor] as CFArray
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            ctx.cgContext.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        }
        #endif
    }

    // MARK: Robôs

    @MainActor
    func syncRobots(_ slots: [RobotSlot]) {
        for (id, v) in robots where !slots.contains(where: { $0.id == id }) {
            v.root.removeFromParentNode(); robots[id] = nil
        }
        for s in slots {
            let v = robots[s.id] ?? RobotVisual()
            if robots[s.id] == nil { world.addChildNode(v.root); robots[s.id] = v }
            build(v, s.model)
            updateRobot(s)
        }
    }

    private func build(_ v: RobotVisual, _ robot: RobotModel) {
        let keep = v.models.compactMap { $0 } + [v.sledModel, v.toolModel].compactMap { $0 } + Array(v.partModels.values)
        v.root.childNodes.filter { n in !keep.contains { $0 === n } }.forEach { $0.removeFromParentNode() }
        v.jointNodes = []
        v.linkNodes = []
        v.size = max(robot.joints.map { abs($0.a) + abs($0.d) }.max() ?? 1000, 500) * 0.12
        let r = v.size
        _ = r
        // sem robô simplificado: os nós ficam só como esqueleto (sem geometria); o que aparece é o modelo real (HSF)
        let base = SCNNode()
        v.root.addChildNode(base)
        v.jointNodes.append(base)
        for i in robot.joints.indices {
            let radius = r * (i < 3 ? 1.0 : 0.62)
            _ = radius
            let j = SCNNode()
            v.root.addChildNode(j)
            v.jointNodes.append(j)
            let l1 = SCNNode(), l2 = SCNNode()
            v.root.addChildNode(l1)
            v.root.addChildNode(l2)
            v.linkNodes.append((l1, l2))
        }
        // ferramenta (corpo até o TCP) e jato/cordão
        v.tool.childNodes.forEach { $0.removeFromParentNode() }
        v.tool.addChildNode(SCNNode())
        v.root.addChildNode(v.tool)
        let cone = SCNCone(topRadius: 0, bottomRadius: 1, height: 1)
        let cm = SCNMaterial()
        cm.diffuse.contents = PlatformColor(calibratedRed: 1, green: 0.55, blue: 0.1, alpha: 0.45)
        cm.isDoubleSided = true
        cm.writesToDepthBuffer = false
        cm.lightingModel = .constant
        cone.materials = [cm]
        let coneNode = SCNNode(geometry: cone)
        coneNode.eulerAngles.x = -.pi / 2
        v.spray.childNodes.forEach { $0.removeFromParentNode() }
        v.spray.addChildNode(coneNode)
        v.spray.isHidden = true
        v.root.addChildNode(v.spray)
        // trilho: barra ao longo do curso
        v.rail.childNodes.forEach { $0.removeFromParentNode() }
        // (o trilho também só aparece pelo modelo real)
        // nome do robô (como "R11" na vista do DXQ)
        let text = SCNText(string: robot.name, extrusionDepth: 0)
        text.font = PlatformFont.systemFont(ofSize: 160, weight: .semibold)
        text.firstMaterial?.diffuse.contents = PlatformColor.white
        text.firstMaterial?.lightingModel = .constant
        v.label.geometry = text
        v.label.constraints = [SCNBillboardConstraint()]
        v.root.addChildNode(v.label)
    }

    @MainActor
    func updateRobot(_ s: RobotSlot) {
        guard let v = robots[s.id] else { return }
        v.root.isHidden = s.hidden3D
        v.railModel?.isHidden = s.hidden3D       // o trilho fixo fica fora do nó do robô
        let robot = s.model
        let frames = Kinematics.frames(robot, s.joints)
        guard frames.count == robot.joints.count + 1, v.jointNodes.count == frames.count else { return }
        let r = v.size
        let b = frames[0]
        // pedestal: do frame da base até o chão (Z=0) quando o robô está elevado
        place(v.jointNodes[0], from: Vec3(b.position.x, b.position.y, 0), to: b.position)
        for i in 0..<robot.joints.count {
            let f = frames[i], next = frames[i + 1]
            let j = robot.joints[i]
            let size = r * (i < 3 ? 1.0 : 0.62)
            place(v.jointNodes[i + 1], from: f.position - f.zAxis * size * 1.15, to: f.position + f.zAxis * size * 1.15)
            let mid = f.position + f.zAxis * j.d
            place(v.linkNodes[i].0, from: f.position, to: mid)
            place(v.linkNodes[i].1, from: mid, to: next.position)
        }
        var rr = robot
        rr.tool = v.tool6
        let flange = frames.last!
        let tcp = flange * v.tool6.matrix
        place(v.tool.childNodes[0], from: flange.position, to: tcp.position)
        v.tool.isHidden = simd_distance(flange.position, tcp.position) < 1
        v.spray.simdTransform = simd_float4x4(tcp)
        if robot.railEnabled, let bar = v.rail.childNodes.first {
            let origin = robot.base.matrix * robot.railPre.matrix
            let a = origin * Mat4.translation(Vec3(0, 0, robot.railMin - 400))
            let c = origin * Mat4.translation(Vec3(0, 0, robot.railMax + 400))
            let mid = (a.position + c.position) / 2 - Vec3(0, 0, r * 1.6)
            let dir = simd_normalize(c.position - a.position)
            let len = simd_distance(a.position, c.position)
            let side = simd_normalize(simd_cross(Vec3(0, 0, 1), dir))
            let up = simd_cross(dir, side)
            bar.simdTransform = simd_float4x4(Mat4(columns: (SIMD4(dir * len, 0), SIMD4(up * r * 0.6, 0), SIMD4(side * r * 3, 0), SIMD4(mid, 1))))
        }
        v.label.position = SCNVector3(frames[3].position.x, frames[3].position.y, frames[3].position.z + r * 2.5)
        let hasModel = v.models.contains { $0 != nil }
        v.label.isHidden = !hasModel          // sem modelo real o robô não aparece (o motivo vai para Mensagens)
        if hasModel {
            for (n, node) in v.models.enumerated() where n < frames.count {
                node?.simdTransform = simd_float4x4(frames[n]) * simd_float4x4(diagonal: SIMD4(1000, 1000, 1000, 1))
            }
        }
        // equipamentos: trilho fixo no frame (base · preLink), carro no frame após o trilho
        let down = Mat4.translation(Vec3(0, 0, v.rootOffset))
        if let rail = v.railModel {
            rail.simdTransform = simd_float4x4(robot.base.matrix * down * robot.railPre.matrix)
        }
        if let sled = v.sledModel { sled.simdTransform = simd_float4x4(frames[0] * down) }
        for (j, n) in v.partModels where j < frames.count { n.simdTransform = simd_float4x4(frames[j]) }
        if let t = v.toolModel { t.simdTransform = simd_float4x4(flange) }
        v.tool.isHidden = v.tool.isHidden || v.toolModel != nil
        for j in v.jointNodes { j.isHidden = j.isHidden || hasModel }
        for (a, b) in v.linkNodes { a.isHidden = a.isHidden || hasModel; b.isHidden = b.isHidden || hasModel }
    }

    struct Extras {
        var rail: [([HSFPart], Double)] = []   // (peça, posição ao longo do eixo em mm)
        var sled: [HSFPart] = []
        var parts: [Int: [HSFPart]] = [:]
        var tool: [HSFPart] = []
        var rootOffset: Double = 0             // mm
    }

    private func meshNode(_ parts: [HSFPart]) -> SCNNode? {
        guard !parts.isEmpty else { return nil }
        let node = SCNNode()
        var groups: [SIMD3<Float>: [HSFPart]] = [:]
        for p in parts { groups[p.color ?? SIMD3(0.78, 0.78, 0.8), default: []].append(p) }
        for (c, ps) in groups {
            var pos: [SIMD3<Float>] = [], idx: [UInt32] = []
            for p in ps {
                let base = UInt32(pos.count)
                pos += p.positions.map { $0 * 1000 }      // metros → mm
                idx += p.indices.map { $0 + base }
            }
            let g = Self.geometry(Mesh(positions: pos, indices: idx))
            let m = SCNMaterial()
            let isGray = abs(c.x - c.y) < 0.08 && abs(c.y - c.z) < 0.08
            m.diffuse.contents = isGray ? PlatformColor(calibratedWhite: CGFloat(max(c.x, 0.55)), alpha: 1)
                                        : PlatformColor(calibratedRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
            m.lightingModel = .physicallyBased
            m.metalness.contents = 0.25
            m.roughness.contents = 0.5
            m.isDoubleSided = true
            g.materials = [m]
            node.addChildNode(SCNNode(geometry: g))
        }
        return node
    }

    /// Trilho, carro, peças do punho e ferramenta (posicionados em updateRobot).
    @MainActor
    func setRobotExtras(_ slot: RobotSlot, _ e: Extras) {
        guard let v = robots[slot.id] else { return }
        [v.railModel, v.sledModel, v.toolModel].forEach { $0?.removeFromParentNode() }
        v.partModels.values.forEach { $0.removeFromParentNode() }
        v.partModels = [:]
        v.rootOffset = e.rootOffset
        if !e.rail.isEmpty {
            let rail = SCNNode()
            for (parts, pos) in e.rail {
                if let n = meshNode(parts) { n.position = SCNVector3(0, 0, pos); rail.addChildNode(n) }
            }
            v.railModel = rail
            // robô já removido da Vista 3D enquanto os modelos carregavam: o trilho nasce escondido
            rail.isHidden = AppState.shared?.robots.first { $0.id == slot.id }?.hidden3D ?? slot.hidden3D
            world.addChildNode(rail)
        } else { v.railModel = nil }
        v.sledModel = meshNode(e.sled)
        v.toolModel = meshNode(e.tool)
        for (j, ps) in e.parts { if let n = meshNode(ps) { v.partModels[j] = n } }
        for n in [v.sledModel, v.toolModel].compactMap({ $0 }) + Array(v.partModels.values) { v.root.addChildNode(n) }
        v.rail.isHidden = v.railModel != nil
        updateRobot(slot)
    }

    /// Recebe as malhas dos elos (metros, no sistema de cada elo) e substitui os cilindros.
    @MainActor
    func setRobotModels(_ slot: RobotSlot, links: [[HSFPart]]) {
        guard let v = robots[slot.id] else { return }
        v.models.forEach { $0?.removeFromParentNode() }
        v.models = links.map { parts in
            guard !parts.isEmpty else { return nil }
            let node = SCNNode()
            // agrupa por cor para reduzir o número de geometrias
            var groups: [SIMD3<Float>: [HSFPart]] = [:]
            for p in parts { groups[p.color ?? SIMD3(0.78, 0.78, 0.8), default: []].append(p) }
            for (color, ps) in groups {
                var pos: [SIMD3<Float>] = [], idx: [UInt32] = []
                for p in ps {
                    let base = UInt32(pos.count)
                    pos += p.positions
                    idx += p.indices.map { $0 + base }
                }
                let mesh = Mesh(positions: pos, indices: idx)
                let g = Self.geometry(mesh)
                let m = SCNMaterial()
                // cores do DXQ: cinza metálico claro; preserva cores marcantes do arquivo
                let c = color
                let isGray = abs(c.x - c.y) < 0.08 && abs(c.y - c.z) < 0.08
                m.diffuse.contents = isGray ? PlatformColor(calibratedWhite: CGFloat(max(c.x, 0.55)), alpha: 1)
                                            : PlatformColor(calibratedRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
                m.lightingModel = .physicallyBased
                m.metalness.contents = 0.25
                m.roughness.contents = 0.45
                m.isDoubleSided = true
                g.materials = [m]
                node.addChildNode(SCNNode(geometry: g))
            }
            v.root.addChildNode(node)
            return node
        }
        updateRobot(slot)
    }

    static func geometry(_ mesh: Mesh) -> SCNGeometry {
        let pos = SCNGeometrySource(data: mesh.positions.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .vertex,
                                    vectorCount: mesh.positions.count, usesFloatComponents: true, componentsPerVector: 3,
                                    bytesPerComponent: 4, dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride)
        let nrm = SCNGeometrySource(data: mesh.normals.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .normal,
                                    vectorCount: mesh.normals.count, usesFloatComponents: true, componentsPerVector: 3,
                                    bytesPerComponent: 4, dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride)
        let el = SCNGeometryElement(data: mesh.indices.withUnsafeBufferPointer { Data(buffer: $0) }, primitiveType: .triangles,
                                    primitiveCount: mesh.indices.count / 3, bytesPerIndex: 4)
        return SCNGeometry(sources: [pos, nrm], elements: [el])
    }

    /// Materiais originais dos robôs pintados de vermelho (erro de simulação), para restaurar.
    private var errorMaterials: [ObjectIdentifier: (SCNGeometry, [SCNMaterial])] = [:]
    private var errorRobots = Set<UUID>()

    /// Robô em erro (como `MarkCurrentPositionAsInvalid` no DXQ): todo o robô fica vermelho até a próxima simulação.
    func setRobotError(_ id: UUID, _ on: Bool) {
        guard let v = robots[id], on != errorRobots.contains(id) else { return }
        if on { errorRobots.insert(id) } else { errorRobots.remove(id) }
        v.root.enumerateHierarchy { node, _ in
            guard let g = node.geometry, node !== v.label else { return }
            let key = ObjectIdentifier(node)
            if on {
                if errorMaterials[key] == nil {
                    // cópia própria: os materiais podem ser compartilhados com outros robôs
                    let copy = g.copy() as! SCNGeometry
                    copy.materials = g.materials.map { m in
                        let c = m.copy() as! SCNMaterial
                        c.multiply.contents = PlatformColor(calibratedRed: 1, green: 0.25, blue: 0.2, alpha: 1)
                        c.emission.contents = PlatformColor(calibratedRed: 0.35, green: 0, blue: 0, alpha: 1)
                        return c
                    }
                    errorMaterials[key] = (g, g.materials)
                    node.geometry = copy
                }
            } else if let (orig, _) = errorMaterials.removeValue(forKey: key) {
                node.geometry = orig
            }
        }
    }

    func clearRobotErrors() { for id in errorRobots { setRobotError(id, false) } }

    func highlight(robot id: UUID?) {
        for (rid, v) in robots {
            v.label.geometry?.firstMaterial?.diffuse.contents = rid == id ? PlatformColor.white : PlatformColor(calibratedWhite: 0.85, alpha: 0.7)
        }
    }

    @MainActor
    func setSpray(robot id: UUID?, on: Bool, brush: Brush, tool: Pose) {
        guard let id, let v = robots[id] else { return }
        v.tool6 = tool
        v.spray.isHidden = !on
        let length = 300.0
        let radius = length * tan(rad(brush.coneHalfAngle))
        v.spray.childNodes.first?.scale = SCNVector3(max(radius, 4), length, max(radius, 4))
        v.spray.childNodes.first?.position = SCNVector3(0, 0, length / 2)
        if let app = AppState.shared, let i = app.robots.firstIndex(where: { $0.id == id }) { updateRobot(app.robots[i]) }
    }

    /// Posiciona um cilindro unitário (eixo Y, altura 1) entre dois pontos.
    private func place(_ node: SCNNode, from a: Vec3, to b: Vec3) {
        let v = b - a
        let len = simd_length(v)
        node.isHidden = len < 1e-3
        guard len >= 1e-3 else { return }
        let y = v / len
        let ref = abs(y.z) < 0.9 ? Vec3(0, 0, 1) : Vec3(1, 0, 0)
        let x = simd_normalize(simd_cross(y, ref))
        let z = simd_cross(x, y)
        let c = (a + b) / 2
        node.simdTransform = simd_float4x4(Mat4(columns: (SIMD4(x, 0), SIMD4(y * len, 0), SIMD4(z, 0), SIMD4(c, 1))))
    }

    // MARK: Câmera

    enum ViewPreset { case iso, top, front, side, back, left, bottom }

    func setView(_ preset: ViewPreset) {
        let (center, radius) = sceneBounds()
        let c = world.convertPosition(SCNVector3(center.x, center.y, center.z), to: nil)
        let d = SCNFloat(radius * 0.001 * 1.7)
        // direções em coordenadas do SceneKit (Y para cima; X da estação = X, Y da estação = −Z)
        let dir: SCNVector3
        switch preset {
        case .iso: dir = SCNVector3(0.62, 0.5, 0.62)
        case .top: dir = SCNVector3(0, 1, 0.0001)
        case .front: dir = SCNVector3(1, 0.05, 0)
        case .side: dir = SCNVector3(0, 0.05, 1)
        case .back: dir = SCNVector3(-1, 0.05, 0)
        case .left: dir = SCNVector3(0, 0.05, -1)
        case .bottom: dir = SCNVector3(0, -1, 0.0001)
        }
        pushCameraHistory()
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.4
        let pov = view?.pointOfView ?? cameraNode
        let x = c.x + dir.x * d, y = c.y + dir.y * d, z = c.z + dir.z * d
        pov.position = SCNVector3(x, y, z)
        pov.look(at: c)
        view?.defaultCameraController.target = c
        SCNTransaction.commit()
    }

    func frameAll() { setView(.iso) }

    func sceneBounds() -> (Vec3, Double) {
        var lo = Vec3(repeating: .infinity), hi = Vec3(repeating: -.infinity)
        func add(_ node: SCNNode) {
            let (a, b) = node.boundingBox
            // Com OBJECT rotacionado, os oito cantos são necessários para enquadrar a peça.
            for x in [a.x, b.x] { for y in [a.y, b.y] { for z in [a.z, b.z] {
                let w = world.convertPosition(SCNVector3(x, y, z), from: node)
                lo = simd_min(lo, Vec3(Double(w.x), Double(w.y), Double(w.z)))
                hi = simd_max(hi, Vec3(Double(w.x), Double(w.y), Double(w.z)))
            } } }
        }
        for v in robots.values { add(v.root); if let r = v.railModel { add(r) } }
        for p in partNodes.values { add(p) }
        if lo.x == .infinity { return (Vec3(0, 0, 800), 3000) }
        return ((lo + hi) / 2, max(simd_distance(lo, hi) / 2, 1000))
    }

    // MARK: Trajetória

    /// Destaque de uma sugestão da análise: caminho atual (vermelho), proposto (verde) e ponto de risco (esfera).
    private var analysisNode: SCNNode?
    func showAnalysisHighlight(current: [Vec3], proposed: [Vec3], marker: Vec3?) {
        analysisNode?.removeFromParentNode()
        let root = SCNNode()
        func tube(_ pts: [Vec3], _ color: PlatformColor, _ radius: Double) {
            let m = SCNMaterial(); m.diffuse.contents = color; m.lightingModel = .constant
            for k in 0..<Swift.max(pts.count - 1, 0) {
                let n = SCNNode(geometry: SCNCylinder(radius: radius, height: 1))
                n.geometry!.materials = [m]
                place(n, from: pts[k], to: pts[k + 1])
                root.addChildNode(n)
            }
            for p in [pts.first, pts.last].compactMap({ $0 }) {
                let s = SCNNode(geometry: SCNSphere(radius: radius * 2.2)); s.geometry!.materials = [m]
                s.simdPosition = SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z)); root.addChildNode(s)
            }
        }
        if current.count > 1 { tube(current, PlatformColor(calibratedRed: 0.95, green: 0.2, blue: 0.15, alpha: 1), 7) }
        if proposed.count > 1 { tube(proposed, PlatformColor(calibratedRed: 0.1, green: 0.85, blue: 0.3, alpha: 1), 7) }
        if let marker {
            let m = SCNMaterial(); m.diffuse.contents = PlatformColor(calibratedRed: 1, green: 0.1, blue: 0.1, alpha: 0.35); m.lightingModel = .constant
            m.isDoubleSided = true
            let s = SCNNode(geometry: SCNSphere(radius: 150)); s.geometry!.materials = [m]
            s.simdPosition = SIMD3<Float>(Float(marker.x), Float(marker.y), Float(marker.z))
            root.addChildNode(s)
        }
        world.addChildNode(root)
        analysisNode = root
    }

    func clearAnalysisHighlight() { analysisNode?.removeFromParentNode(); analysisNode = nil }


    // MARK: Caminhos (estilo da Vista 3D do DXQ: H3DProgramStyle / H3DCommandDefinition / ProgramCfg)

    /// Cores dos pincéis do DXQ (H3DCommandDefinition.BrushColors; índice = |pincel| mod 10).
    static let brushColors: [SIMD3<Float>] = [[0, 0.75, 0.75], [0, 1, 0], [0, 1, 1], [1, 0, 0], [1, 0, 1],
                                              [0.5, 0, 0], [0, 0.5, 0.5], [0, 0, 1], [1, 1, 0], [0.5, 0.5, 0.5]]
    static func brushColor(_ brush: Int) -> PlatformColor {
        let c = brushColors[abs(brush) % brushColors.count]
        return PlatformColor(calibratedRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
    }
    /// Caminho selecionado: verde (style_program_path_sel). Vários robôs: uma cor por robô.
    private static let selectedPathColor = PlatformColor(calibratedRed: 0, green: 1, blue: 0, alpha: 1)
    private static let robotPathColors: [PlatformColor] = [
        PlatformColor(calibratedRed: 0, green: 1, blue: 0, alpha: 1), PlatformColor(calibratedRed: 0, green: 1, blue: 1, alpha: 1),
        PlatformColor(calibratedRed: 1, green: 1, blue: 0, alpha: 1), PlatformColor(calibratedRed: 1, green: 0.5, blue: 0, alpha: 1),
        PlatformColor(calibratedRed: 0.5, green: 0.5, blue: 1, alpha: 1)]
    /// Pontos: Object cinza 0,75, Axis cinza 0,3 (style_program_point_obj/joint); cone 10×20 mm (PointCone).
    private static let pointObjectColor = PlatformColor(calibratedWhite: 0.75, alpha: 1)
    private static let pointAxisColor = PlatformColor(calibratedWhite: 0.3, alpha: 1)
    /// Seleção: vermelho (AppearanceCfg.SelectionColor).
    static let selectionColor = PlatformColor(calibratedRed: 1, green: 0, blue: 0, alpha: 1)

    private var coneGeometries: [String: SCNGeometry] = [:]
    /// Cone compartilhado por cor (milhares de pontos sem uma geometria cada).
    private func cone(_ color: PlatformColor, radius: CGFloat = 10, height: CGFloat = 20) -> SCNGeometry {
        let key = "\(color.description)/\(radius)/\(height)"
        if let g = coneGeometries[key] { return g }
        let g = SCNCone(topRadius: 0, bottomRadius: radius, height: height)
        g.radialSegmentCount = 12
        let m = SCNMaterial(); m.diffuse.contents = color; m.lightingModel = .lambert
        g.materials = [m]
        coneGeometries[key] = g
        return g
    }

    /// Nó no ponto com o eixo Y local na direção `dir` e a geometria (cone) começando no ponto.
    private func coneNode(at p: Vec3, dir: Vec3, side: Vec3, geometry: SCNGeometry, height: Double) -> SCNNode {
        let y = simd_normalize(dir)
        var x = side - y * simd_dot(side, y)
        if simd_length(x) < 1e-6 { x = abs(y.z) < 0.9 ? simd_cross(y, Vec3(0, 0, 1)) : simd_cross(y, Vec3(1, 0, 0)) }
        x = simd_normalize(x)
        let z = simd_cross(x, y)
        let n = SCNNode()
        n.simdTransform = simd_float4x4(Mat4(columns: (SIMD4(x, 0), SIMD4(y, 0), SIMD4(z, 0), SIMD4(p, 1))))
        let c = SCNNode(geometry: geometry)
        c.position = SCNVector3(0, height / 2, 0)
        n.addChildNode(c)
        return n
    }

    func showPath(_ prog: RobotProgram, unreachable: Set<Int> = []) {
        showPaths([(program: prog, unreachable: unreachable)])
    }

    /// Caminhos como a Vista 3D do DXQ: linha do caminho (verde no selecionado, uma cor por robô na estação),
    /// trecho com pistola ligada na cor do pincel, cone em cada ponto apontando na direção da ferramenta (Z),
    /// cones de direção no meio de cada trecho e pontos fora de alcance em vermelho.
    func showPaths(_ entries: [(program: RobotProgram, unreachable: Set<Int>)]) {
        pathNode.childNodes.forEach { $0.removeFromParentNode() }
        framesNode.childNodes.forEach { $0.removeFromParentNode() }
        pathSpheres = []
        selectedPathPoints = []
        savedPointGeometry = [:]
        let multi = entries.filter { !$0.program.points.isEmpty }.count > 1
        for (entryIndex, entry) in entries.enumerated() {
            guard !entry.program.points.isEmpty else { pathSpheres.append([]); continue }
            let prog = entry.program
            let pathColor = multi ? Self.robotPathColors[entryIndex % Self.robotPathColors.count] : Self.selectedPathColor
            var verts: [SCNVector3] = []
            var points: [SCNNode] = []
            let pts = prog.points.map { $0.pose.position }
            for (i, p) in prog.points.enumerated() {
                verts.append(SCNVector3(p.pose.x, p.pose.y, p.pose.z))
                let color = entry.unreachable.contains(i) ? PlatformColor.systemRed : (p.joints != nil ? Self.pointAxisColor : Self.pointObjectColor)
                let m = p.pose.matrix
                let n = coneNode(at: pts[i], dir: m.zAxis, side: m.xAxis, geometry: cone(color), height: 20)
                n.name = "pt"; n.isHidden = !pathLayers.points
                pathNode.addChildNode(n)
                points.append(n)
            }
            pathSpheres.append(points)
            if verts.count > 1 {
                // linha do caminho
                let src = SCNGeometrySource(vertices: verts)
                var idx: [Int32] = []
                for i in 0..<(verts.count - 1) { idx += [Int32(i), Int32(i + 1)] }
                let g = SCNGeometry(sources: [src], elements: [SCNGeometryElement(indices: idx, primitiveType: .line)])
                let m = SCNMaterial(); m.diffuse.contents = pathColor; m.lightingModel = .constant
                g.materials = [m]
                pathNode.addChildNode(SCNNode(geometry: g))
                // pistola ligada: trecho grosso na cor do pincel (style_program_path_unsel_gunon_linewidth = 4)
                var tubeMats: [Int: SCNMaterial] = [:]
                for i in 1..<prog.points.count where prog.points[i].paintOn {
                    let b = abs(prog.points[i].brush) % Self.brushColors.count
                    let mat = tubeMats[b] ?? { let m = SCNMaterial(); m.diffuse.contents = Self.brushColor(b); m.lightingModel = .constant; return m }()
                    tubeMats[b] = mat
                    let tube = SCNNode(geometry: SCNCylinder(radius: 5, height: 1))
                    tube.geometry!.materials = [mat]
                    place(tube, from: pts[i - 1], to: pts[i])
                    tube.name = "gun"; tube.isHidden = tube.isHidden || !pathLayers.triggers
                    pathNode.addChildNode(tube)
                }
                // cones de direção do movimento no meio de cada trecho (DirCone 10×20 mm)
                let dirCone = cone(pathColor, radius: 7, height: 16)
                for i in 1..<pts.count {
                    let v = pts[i] - pts[i - 1]
                    guard simd_length(v) > 60 else { continue }
                    let mid = (pts[i] + pts[i - 1]) / 2 - simd_normalize(v) * 8
                    let dn = coneNode(at: mid, dir: v, side: Vec3(0, 0, 1), geometry: dirCone, height: 16)
                    dn.name = "dir"; dn.isHidden = !pathLayers.cones
                    pathNode.addChildNode(dn)
                }
            }
        }
    }

    // MARK: Seleção de pontos no 3D

    /// Ponto do caminho mais perto do clique (em pixels na tela), como a seleção de pontos da Vista 3D do DXQ.
    func pathPoint(at p: CGPoint, tolerance: CGFloat = Platform.isMac ? 10 : 22) -> (entry: Int, index: Int)? {
        guard let v = view, !pathNode.isHidden else { return nil }
        var best: (entry: Int, index: Int, d: CGFloat, z: CGFloat)?
        for (e, list) in pathSpheres.enumerated() {
            for (i, n) in list.enumerated() {
                let q = v.projectPoint(n.worldPosition)
                guard q.z > 0, q.z < 1 else { continue }
                let qz = CGFloat(q.z)     // SCNVector3 é CGFloat no Mac e Float no iOS
                let d = hypot(CGFloat(q.x) - p.x, CGFloat(q.y) - p.y)
                guard d <= tolerance else { continue }
                // mais perto do clique; empate → mais perto da câmera
                if best == nil || d < best!.d - 0.5 || (abs(d - best!.d) <= 0.5 && qz < best!.z) { best = (e, i, d, qz) }
            }
        }
        return best.map { ($0.entry, $0.index) }
    }

    private(set) var selectedPathPoints: Set<Int> = []
    /// Onde o ponto aparece na tela (diagnóstico do clique).
    func screenPoint(entry: Int, index: Int) -> CGPoint? {
        guard let v = view, pathSpheres.indices.contains(entry), pathSpheres[entry].indices.contains(index) else { return nil }
        let q = v.projectPoint(pathSpheres[entry][index].worldPosition)
        return CGPoint(x: CGFloat(q.x), y: CGFloat(q.y))
    }
    var pathPointCount: Int { pathSpheres.first?.count ?? 0 }
    private var pathSpheres: [[SCNNode]] = []
    private var savedPointGeometry: [Int: SCNGeometry] = [:]

    /// Destaca (vermelho, cor de seleção do DXQ, e maior) os pontos selecionados do caminho `entry`.
    func highlightPathPoints(_ indices: Set<Int>, entry: Int = 0) {
        guard pathSpheres.indices.contains(entry) else { return }
        let list = pathSpheres[entry]
        let selected = cone(Self.selectionColor)
        for i in selectedPathPoints.subtracting(indices) where list.indices.contains(i) {
            if let g = savedPointGeometry.removeValue(forKey: i) { list[i].childNodes.first?.geometry = g }
            list[i].scale = SCNVector3(1, 1, 1)
        }
        for i in indices.subtracting(selectedPathPoints) where list.indices.contains(i) {
            savedPointGeometry[i] = list[i].childNodes.first?.geometry
            list[i].childNodes.first?.geometry = selected
            list[i].scale = SCNVector3(1.8, 1.8, 1.8)
        }
        selectedPathPoints = indices.filter { list.indices.contains($0) }
    }

    // MARK: Peças

    func setPart(_ part: Part, displayMesh mesh: Mesh) {
        partNodes[part.id]?.removeFromParentNode()
        let pos = SCNGeometrySource(data: mesh.positions.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .vertex,
                                    vectorCount: mesh.positions.count, usesFloatComponents: true, componentsPerVector: 3,
                                    bytesPerComponent: 4, dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride)
        let nrm = SCNGeometrySource(data: mesh.normals.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .normal,
                                    vectorCount: mesh.normals.count, usesFloatComponents: true, componentsPerVector: 3,
                                    bytesPerComponent: 4, dataOffset: 0, dataStride: MemoryLayout<SIMD3<Float>>.stride)
        let el = SCNGeometryElement(data: mesh.indices.withUnsafeBufferPointer { Data(buffer: $0) }, primitiveType: .triangles,
                                    primitiveCount: mesh.indices.count / 3, bytesPerIndex: 4)
        partGeometry[part.id] = (pos, nrm, el, mesh.positions.count)
        let node = SCNNode(geometry: makePartGeometry(part.id, colors: nil))
        node.simdTransform = simd_float4x4(part.offset.matrix)
        node.name = part.name
        world.addChildNode(node)
        partNodes[part.id] = node
    }

    private func makePartGeometry(_ id: UUID, colors: [SIMD4<Float>]?) -> SCNGeometry? {
        guard let g = partGeometry[id] else { return nil }
        var sources = [g.positions, g.normals]
        if let colors {
            sources.append(SCNGeometrySource(data: colors.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: .color,
                                             vectorCount: colors.count, usesFloatComponents: true, componentsPerVector: 4,
                                             bytesPerComponent: 4, dataOffset: 0, dataStride: 16))
        }
        let geo = SCNGeometry(sources: sources, elements: [g.element])
        let m = SCNMaterial()
        m.diffuse.contents = colors == nil ? PlatformColor(calibratedWhite: 0.9, alpha: 1) : PlatformColor.white
        m.lightingModel = .physicallyBased
        m.roughness.contents = 0.6
        m.isDoubleSided = true
        geo.materials = [m]
        return geo
    }

    func colorPart(id: UUID, thickness: [Float], target: Float) {
        guard let g = partGeometry[id], g.count == thickness.count, let node = partNodes[id] else { return }
        node.geometry = makePartGeometry(id, colors: thickness.map { Self.colorMap($0, target: target) })
    }

    /// Cinza = sem tinta; azul → verde (na meta) → vermelho (2× a meta).
    static func colorMap(_ t: Float, target: Float) -> SIMD4<Float> {
        if t < 0.5 { return [0.9, 0.9, 0.9, 1] }
        let x = min(t / (2 * target), 1)
        let stops: [(Float, SIMD3<Float>)] = [(0, [0.1, 0.2, 0.9]), (0.25, [0, 0.7, 1]), (0.5, [0.1, 0.85, 0.2]), (0.75, [1, 0.85, 0]), (1, [0.9, 0.1, 0.1])]
        for k in 1..<stops.count where x <= stops[k].0 {
            let f = (x - stops[k - 1].0) / (stops[k].0 - stops[k - 1].0)
            return SIMD4(stops[k - 1].1 + (stops[k].1 - stops[k - 1].1) * f, 1)
        }
        return [0.9, 0.1, 0.1, 1]
    }

    func movePart(id: UUID, pose: Pose) { partNodes[id]?.simdTransform = simd_float4x4(pose.matrix) }

    func removePart(id: UUID) {
        partNodes[id]?.removeFromParentNode()
        partNodes[id] = nil
        partGeometry[id] = nil
    }

    private func buildGrid() {
        var verts: [SCNVector3] = []
        let half = 6000.0, step = 500.0
        var v = -half
        while v <= half {
            verts += [SCNVector3(v, -half, 0), SCNVector3(v, half, 0), SCNVector3(-half, v, 0), SCNVector3(half, v, 0)]
            v += step
        }
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: verts)],
                            elements: [SCNGeometryElement(indices: (0..<Int32(verts.count)).map { $0 }, primitiveType: .line)])
        let m = SCNMaterial()
        m.diffuse.contents = PlatformColor(calibratedWhite: 1, alpha: 0.25)
        m.lightingModel = .constant
        g.materials = [m]
        gridNode.addChildNode(SCNNode(geometry: g))
        // sistema de coordenadas da estação: X vermelho, Y verde, Z azul (como no DXQ)
        for (dir, color) in [(SCNVector3(800, 0, 0), PlatformColor.systemRed), (SCNVector3(0, 800, 0), PlatformColor.systemGreen), (SCNVector3(0, 0, 800), PlatformColor.systemBlue)] {
            let ag = SCNGeometry(sources: [SCNGeometrySource(vertices: [SCNVector3(0, 0, 0), dir])],
                                 elements: [SCNGeometryElement(indices: [Int32(0), 1], primitiveType: .line)])
            let am = SCNMaterial(); am.diffuse.contents = color; am.lightingModel = .constant
            ag.materials = [am]
            gridNode.addChildNode(SCNNode(geometry: ag))
        }
    }
}

extension simd_float4x4 {
    init(_ m: Mat4) {
        self.init(columns: (SIMD4<Float>(m.columns.0), SIMD4<Float>(m.columns.1), SIMD4<Float>(m.columns.2), SIMD4<Float>(m.columns.3)))
    }
}

// MARK: - Vista 3D do DXQ: navegação, histórico de câmera, projeção, modos de renderização, chão, medir

enum RenderMode: String, CaseIterable, Identifiable {
    case shaded = "Sombreado", wireframe = "Arame", transparent = "Transparente", invisible = "Invisível"
    var id: String { rawValue }
    /// ícone do DXQ (rendermode…)
    var icon: String {
        switch self {
        case .shaded: return "3dgraphic_rendermodegouraudshaded"
        case .wireframe: return "3dgraphic_rendermodewireframe"
        case .transparent: return "3dgraphic_rendermodetransparent"
        case .invisible: return "3dgraphic_rendermodeinvisible"
        }
    }
}

enum NavigateMode: String { case orbit, pan, zoom }

extension SceneController {
    // Navegar (Orbitar / Deslocar / Zoom): o que o arrasto com o botão esquerdo faz
    func setNavigateMode(_ m: NavigateMode) {
        guard let v = view else { return }
        switch m {
        case .orbit: v.defaultCameraController.interactionMode = .orbitTurntable
        case .pan: v.defaultCameraController.interactionMode = .pan
        case .zoom: v.defaultCameraController.interactionMode = .truck
        }
    }

    // Vista anterior / próxima (setas da guia Vista 3D)
    func pushCameraHistory() {
        guard let pov = view?.pointOfView else { return }
        let t = pov.simdTransform
        if cameraHistoryIndex < cameraHistory.count - 1 { cameraHistory.removeSubrange((cameraHistoryIndex + 1)...) }
        if let last = cameraHistory.last, simd_almost_equal_elements(last, t, 1e-4) { return }
        cameraHistory.append(t)
        if cameraHistory.count > 50 { cameraHistory.removeFirst() }
        cameraHistoryIndex = cameraHistory.count - 1
    }

    var canGoBackView: Bool { cameraHistoryIndex > 0 }
    var canGoForwardView: Bool { cameraHistoryIndex < cameraHistory.count - 1 }

    func stepCameraHistory(_ delta: Int) {
        guard let pov = view?.pointOfView else { return }
        // a posição atual (girada à mão) entra no histórico antes de voltar
        if delta < 0, cameraHistoryIndex == cameraHistory.count - 1, let last = cameraHistory.last, !simd_almost_equal_elements(last, pov.simdTransform, 1e-4) {
            pushCameraHistory()
        }
        let i = cameraHistoryIndex + delta
        guard cameraHistory.indices.contains(i) else { return }
        cameraHistoryIndex = i
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.35
        pov.simdTransform = cameraHistory[i]
        SCNTransaction.commit()
    }

    // Vista "Home" do DXQ (salvar a atual como home)
    func saveHomeView() { homeView = view?.pointOfView?.simdTransform }
    func goHome() {
        guard let h = homeView, let pov = view?.pointOfView else { frameAll(); return }
        SCNTransaction.begin(); SCNTransaction.animationDuration = 0.4
        pov.simdTransform = h
        SCNTransaction.commit()
        pushCameraHistory()
    }

    // Projeção perspectiva / ortográfica
    var isOrthographic: Bool { view?.pointOfView?.camera?.usesOrthographicProjection ?? false }
    func setOrthographic(_ on: Bool) {
        guard let pov = view?.pointOfView, let cam = pov.camera else { return }
        if on {
            let target = view?.defaultCameraController.target ?? SCNVector3Zero
            let d = simd_distance(pov.simdWorldPosition, SIMD3<Float>(Float(target.x), Float(target.y), Float(target.z)))
            cam.orthographicScale = Double(d) * tan(cam.fieldOfView * .pi / 360)
        }
        cam.usesOrthographicProjection = on
    }

    // Modos de renderização (robô, trilho, ferramenta, peça, célula)
    enum RenderTarget { case robot, rail, tool }
    func nodes(for target: RenderTarget) -> [SCNNode] {
        robots.values.flatMap { v -> [SCNNode] in
            switch target {
            case .robot: return v.models.compactMap { $0 } + Array(v.partModels.values)
            case .rail: return [v.railModel, v.sledModel].compactMap { $0 }
            case .tool: return [v.toolModel].compactMap { $0 }
            }
        }
    }
    func partNode(_ id: UUID) -> SCNNode? { partNodes[id] }

    func apply(_ mode: RenderMode, to nodes: [SCNNode]) {
        for n in nodes {
            n.isHidden = mode == .invisible
            n.opacity = mode == .transparent ? 0.35 : 1
            n.enumerateHierarchy { c, _ in
                for m in c.geometry?.materials ?? [] { m.fillMode = mode == .wireframe ? .lines : .fill }
            }
        }
    }

    // Chão da célula (H3DFloor: retângulo vermelho translúcido em Z = 0, do tamanho da cena)
    func setFloor(_ on: Bool) {
        floorNode?.removeFromParentNode(); floorNode = nil
        guard on else { return }
        let (c, r) = sceneBounds()
        let plane = SCNPlane(width: r * 2, height: r * 2)
        let m = SCNMaterial()
        m.diffuse.contents = PlatformColor(calibratedRed: 1, green: 0, blue: 0, alpha: 0.35)
        m.isDoubleSided = true; m.lightingModel = .constant
        plane.materials = [m]
        let n = SCNNode(geometry: plane)
        n.position = SCNVector3(c.x, c.y, 0)
        world.addChildNode(n)
        floorNode = n
    }

    // Medir distância: ponto da geometria sob o clique (mm, coordenadas da estação)
    func surfacePoint(at p: CGPoint) -> Vec3? {
        guard let v = view else { return nil }
        let hits = v.hitTest(p, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue, .ignoreHiddenNodes: true])
        guard let h = hits.first(where: { $0.node !== measureNode && !($0.node.parent === measureNode) }) else { return nil }
        let w = world.convertPosition(h.worldCoordinates, from: nil)
        return Vec3(Double(w.x), Double(w.y), Double(w.z))
    }

    func showMeasurement(_ pts: [Vec3]) {
        measureNode?.removeFromParentNode(); measureNode = nil
        guard !pts.isEmpty else { return }
        let root = SCNNode()
        let m = SCNMaterial(); m.diffuse.contents = PlatformColor.systemYellow; m.lightingModel = .constant
        for p in pts {
            let s = SCNNode(geometry: SCNSphere(radius: 8)); s.geometry!.materials = [m]
            s.simdPosition = SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z)); root.addChildNode(s)
        }
        if pts.count == 2 {
            let l = SCNNode(geometry: SCNCylinder(radius: 2.5, height: 1)); l.geometry!.materials = [m]
            place(l, from: pts[0], to: pts[1]); root.addChildNode(l)
        }
        world.addChildNode(root)
        measureNode = root
    }

    /// Imagem da Vista 3D (Imprimir / salvar imagem).
    func snapshotImage() -> PlatformImage? { view?.snapshot() }
}
