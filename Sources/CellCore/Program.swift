import Foundation
import simd

public enum MotionType: String, Codable, CaseIterable { case ptp = "PTP", lin = "LIN", circ = "CIRC" }

/// Parâmetros do pincel (brush): como o aplicador deposita tinta.
public struct Brush: Codable, Hashable, Identifiable {
    public var id: Int
    public var name: String
    public var flowRate: Double          // ml/min
    public var coneHalfAngle: Double     // graus
    public var beta: Double              // forma do perfil do leque: maior = mais concentrado no centro
    public var transferEfficiency: Double // 0…1
    public var solids: Double            // fração de sólidos 0…1 (espessura de película seca)

    public init(id: Int, name: String, flowRate: Double = 250, coneHalfAngle: Double = 18, beta: Double = 2, transferEfficiency: Double = 0.75, solids: Double = 0.45) {
        self.id = id; self.name = name; self.flowRate = flowRate; self.coneHalfAngle = coneHalfAngle
        self.beta = beta; self.transferEfficiency = transferEfficiency; self.solids = solids
    }
}

public struct ProgramPoint: Codable, Hashable, Identifiable {
    public var id = UUID()
    public var name: String
    public var motion: MotionType
    public var pose: Pose
    public var rail: Double
    public var speed: Double      // mm/s (LIN) ou % (PTP)
    public var paintOn: Bool
    public var brush: Int
    /// Ferramenta ativa neste movimento (SETTOOL); nil = ferramenta do robô
    public var tool: Pose?
    /// Ponto articular (EcoTalk "Axis"): eixos A1…A6 em graus
    public var joints: [Double]?
    /// Ponto intermediário do CIRC
    public var via: Pose?
    /// % de PTP do VEL em vigor (para avaliar trocar um LIN no ar por PTP sem mexer na velocidade)
    public var ptpSpeed: Double?

    public init(name: String, motion: MotionType = .lin, pose: Pose, rail: Double = 0, speed: Double = 500, paintOn: Bool = false, brush: Int = 1) {
        self.name = name; self.motion = motion; self.pose = pose; self.rail = rail; self.speed = speed; self.paintOn = paintOn; self.brush = brush
    }
}

public struct RobotProgram: Codable, Hashable {
    public var name: String
    public var points: [ProgramPoint]
    public var brushes: [Brush]

    public init(name: String, points: [ProgramPoint] = [], brushes: [Brush] = [Brush(id: 1, name: "Pincel 1")]) {
        self.name = name; self.points = points; self.brushes = brushes
    }

    public func brush(_ id: Int) -> Brush { brushes.first { $0.id == id } ?? brushes.first ?? Brush(id: 1, name: "Pincel 1") }

    /// Programa em zigue-zague sobre um retângulo (vista de cima), pistola apontando para baixo.
    public static func zigzag(minX: Double, maxX: Double, minY: Double, maxY: Double, z: Double, standoff: Double, overlap: Double = 0.5, brush: Brush) -> RobotProgram {
        let width = 2 * standoff * tan(rad(brush.coneHalfAngle))
        let step = Swift.max(width * (1 - overlap), 10)
        var pts: [ProgramPoint] = []
        let zz = z + standoff
        // B = 180 aponta a ferramenta (eixo Z do TCP) para baixo
        pts.append(ProgramPoint(name: "P1", motion: .ptp, pose: Pose(x: minX - 200, y: minY, z: zz + 200, b: 180), speed: 100))
        var y = minY, left = true, i = 2
        while y <= maxY + 1e-6 {
            let x0 = left ? minX - 150 : maxX + 150, x1 = left ? maxX + 150 : minX - 150
            pts.append(ProgramPoint(name: "P\(i)", pose: Pose(x: x0, y: y, z: zz, b: 180), speed: 600, paintOn: false, brush: brush.id)); i += 1
            pts.append(ProgramPoint(name: "P\(i)", pose: Pose(x: x1, y: y, z: zz, b: 180), speed: 600, paintOn: true, brush: brush.id)); i += 1
            y += step; left.toggle()
        }
        pts.append(ProgramPoint(name: "P\(i)", motion: .ptp, pose: Pose(x: minX - 200, y: maxY, z: zz + 300, b: 180), speed: 100))
        return RobotProgram(name: "zigzag", points: pts, brushes: [brush])
    }
}

// MARK: - KUKA KRL (subconjunto)

public enum KRL {
    /// Lê um par .src/.dat da KUKA: PTP/LIN com posição inline ou nomeada (DECL E6POS/POS/FRAME),
    /// $VEL.CP (m/s) e $OUT[n]=TRUE/FALSE como gatilho de pintura.
    public static func parse(src: String, dat: String = "", paintOutput: Int? = nil) -> RobotProgram {
        var named: [String: (Pose, Double)] = [:]
        let declRx = try! NSRegularExpression(pattern: #"DECL\s+(?:E6POS|POS|FRAME|E6AXIS)\s+X?(\w+)\s*=\s*\{([^}]*)\}"#, options: .caseInsensitive)
        for m in declRx.matches(in: dat + "\n" + src, range: NSRange((dat + "\n" + src).startIndex..., in: dat + "\n" + src)) {
            let text = dat + "\n" + src
            let name = String(text[Range(m.range(at: 1), in: text)!]).uppercased()
            named[name] = parseAggregate(String(text[Range(m.range(at: 2), in: text)!]))
        }

        var prog = RobotProgram(name: "KRL")
        var vel = 500.0, paint = false, idx = 1
        for raw in src.components(separatedBy: .newlines) {
            var line = raw
            if let c = line.firstIndex(of: ";") { line = String(line[..<c]) }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            let up = line.uppercased()

            if up.hasPrefix("$VEL.CP"), let v = Double(up.split(separator: "=").last!.trimmingCharacters(in: .whitespaces)) {
                vel = v * 1000
            } else if up.hasPrefix("$OUT["), let close = up.firstIndex(of: "]") {
                let n = Int(up[up.index(up.startIndex, offsetBy: 5)..<close]) ?? -1
                if paintOutput == nil || paintOutput == n { paint = up.contains("TRUE") }
            } else if up.hasPrefix("PTP ") || up.hasPrefix("LIN ") {
                let motion: MotionType = up.hasPrefix("PTP") ? .ptp : .lin
                let arg = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                var target: (Pose, Double)?
                if let o = arg.firstIndex(of: "{"), let c = arg.firstIndex(of: "}") {
                    target = parseAggregate(String(arg[arg.index(after: o)..<c]))
                } else {
                    let key = arg.split(separator: " ").first.map(String.init)?.uppercased() ?? ""
                    target = named[key] ?? named[key.hasPrefix("X") ? String(key.dropFirst()) : key]
                }
                if let (pose, e1) = target {
                    prog.points.append(ProgramPoint(name: "P\(idx)", motion: motion, pose: pose, rail: e1, speed: motion == .ptp ? 100 : vel, paintOn: paint))
                    idx += 1
                }
            }
        }
        return prog
    }

    static func parseAggregate(_ s: String) -> (Pose, Double) {
        var p = Pose(), e1 = 0.0
        for part in s.split(separator: ",") {
            let kv = part.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard kv.count == 2, let v = Double(kv[1].trimmingCharacters(in: .whitespaces)) else { continue }
            switch kv[0].uppercased() {
            case "X": p.x = v
            case "Y": p.y = v
            case "Z": p.z = v
            case "A": p.c = v   // KUKA A (em torno de Z) = Dürr C
            case "B": p.b = v
            case "C": p.a = v   // KUKA C (em torno de X) = Dürr A
            case "E1": e1 = v
            default: break
            }
        }
        return (p, e1)
    }

    /// Gera .src e .dat da KUKA a partir de um programa.
    public static func export(_ prog: RobotProgram, paintOutput: Int = 1) -> (src: String, dat: String) {
        let name = prog.name.replacingOccurrences(of: " ", with: "_")
        var src = "DEF \(name)( )\n", dat = "DEFDAT \(name)\n"
        var paint = false
        func f(_ v: Double) -> String { String(format: "%.3f", v) }
        for p in prog.points {
            if p.paintOn != paint {
                src += "$OUT[\(paintOutput)]=\(p.paintOn ? "TRUE" : "FALSE")\n"
                paint = p.paintOn
            }
            if p.motion == .lin { src += "$VEL.CP=\(f(p.speed / 1000))\n" }
            src += "\(p.motion.rawValue) X\(p.name)\n"
            dat += "DECL E6POS X\(p.name)={X \(f(p.pose.x)),Y \(f(p.pose.y)),Z \(f(p.pose.z)),A \(f(p.pose.c)),B \(f(p.pose.b)),C \(f(p.pose.a)),E1 \(f(p.rail))}\n"
        }
        if paint { src += "$OUT[\(paintOutput)]=FALSE\n" }
        return (src + "END\n", dat + "ENDDAT\n")
    }
}
