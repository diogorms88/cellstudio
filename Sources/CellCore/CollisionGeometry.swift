import Foundation
import simd

/// Geometria simplificada para distância/colisão: cada elo do robô vira uma cápsula (segmento + raio),
/// do pé (base/carro do trilho) até o TCP da ferramenta.
public struct Capsule {
    public var a: SIMD3<Double>
    public var b: SIMD3<Double>
    public var r: Double
    public init(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ r: Double) { self.a = a; self.b = b; self.r = r }

    public var boxMin: SIMD3<Double> { simd_min(a, b) - SIMD3(repeating: r) }
    public var boxMax: SIMD3<Double> { simd_max(a, b) + SIMD3(repeating: r) }
}

public enum RobotGeometry {
    /// Raios (mm) por elo: pé→A1, A1→A2, braço, antebraço, punho (A4→A5, A5→A6), flange→TCP (pistola).
    /// Valores de robô de pintura/vedação médio (EcoRS 16); podem ser ajustados por robô.
    public static let defaultRadii: [Double] = [160, 150, 120, 100, 85, 75, 55]

    public static func capsules(_ robot: RobotModel, _ s: JointState, radii: [Double] = defaultRadii) -> [Capsule] {
        let f = Kinematics.frames(robot, s)
        var out: [Capsule] = []
        for i in 0..<(f.count - 1) {
            let a = f[i].position, b = f[i + 1].position
            out.append(Capsule(a, b, i < radii.count ? radii[i] : 80))
        }
        let tcp = (f.last! * robot.tool.matrix).position
        out.append(Capsule(f.last!.position, tcp, radii.last ?? 55))
        return out
    }

    /// Distância entre dois segmentos (menor distância entre pontos de [p1,q1] e [p2,q2]).
    public static func segmentDistance(_ p1: SIMD3<Double>, _ q1: SIMD3<Double>, _ p2: SIMD3<Double>, _ q2: SIMD3<Double>) -> Double {
        let d1 = q1 - p1, d2 = q2 - p2, r = p1 - p2
        let a = simd_dot(d1, d1), e = simd_dot(d2, d2), f = simd_dot(d2, r)
        var s = 0.0, t = 0.0
        if a <= 1e-9 && e <= 1e-9 { return simd_distance(p1, p2) }
        if a <= 1e-9 {
            t = Swift.min(Swift.max(f / e, 0), 1)
        } else {
            let c = simd_dot(d1, r)
            if e <= 1e-9 {
                s = Swift.min(Swift.max(-c / a, 0), 1)
            } else {
                let b = simd_dot(d1, d2), denom = a * e - b * b
                s = denom > 1e-12 ? Swift.min(Swift.max((b * f - c * e) / denom, 0), 1) : 0
                t = (b * s + f) / e
                if t < 0 { t = 0; s = Swift.min(Swift.max(-c / a, 0), 1) }
                else if t > 1 { t = 1; s = Swift.min(Swift.max((b - c) / a, 0), 1) }
            }
        }
        return simd_distance(p1 + d1 * s, p2 + d2 * t)
    }

    public static func pointSegmentDistance(_ p: SIMD3<Double>, _ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let ab = b - a
        let l = simd_dot(ab, ab)
        let t = l > 1e-12 ? Swift.min(Swift.max(simd_dot(p - a, ab) / l, 0), 1) : 0
        return simd_distance(p, a + ab * t)
    }

    /// Folga entre dois conjuntos de cápsulas (negativa = interpenetração). Devolve também o par de elos.
    public static func clearance(_ x: [Capsule], _ y: [Capsule]) -> (distance: Double, i: Int, j: Int) {
        var best = (Double.infinity, 0, 0)
        for (i, c1) in x.enumerated() {
            for (j, c2) in y.enumerated() {
                // caixas afastadas mais que a melhor folga: não precisa calcular
                let gap = simd_max(c1.boxMin - c2.boxMax, c2.boxMin - c1.boxMax)
                if simd_reduce_max(gap) > best.0 { continue }
                let d = segmentDistance(c1.a, c1.b, c2.a, c2.b) - c1.r - c2.r
                if d < best.0 { best = (d, i, j) }
            }
        }
        return best
    }

    public static func bounds(_ caps: [Capsule]) -> (min: SIMD3<Double>, max: SIMD3<Double>) {
        var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
        for c in caps { lo = simd_min(lo, c.boxMin); hi = simd_max(hi, c.boxMax) }
        return (lo, hi)
    }
}

/// Carroceria (ou qualquer peça) como nuvem de pontos da superfície numa grade, para medir folga robô × peça.
public final class ObstacleGrid {
    let cell: Double
    var cells: [SIMD3<Int32>: [SIMD3<Double>]] = [:]
    public private(set) var pointCount = 0
    public private(set) var boxMin = SIMD3<Double>(repeating: .infinity)
    public private(set) var boxMax = SIMD3<Double>(repeating: -.infinity)

    /// `transform`: posição da peça na estação. Triângulos grandes são subdivididos para não deixar buracos.
    public init(mesh: Mesh, transform: Mat4, cell: Double = 40, spacing: Double = 25) {
        self.cell = cell
        let P = mesh.positions.map { v -> SIMD3<Double> in
            let w = transform * SIMD4<Double>(Double(v.x), Double(v.y), Double(v.z), 1)
            return SIMD3(w.x, w.y, w.z)
        }
        var t = 0
        while t + 2 < mesh.indices.count {
            let a = P[Int(mesh.indices[t])], b = P[Int(mesh.indices[t + 1])], c = P[Int(mesh.indices[t + 2])]
            t += 3
            let n = Swift.max(1, Int(ceil(Swift.max(simd_distance(a, b), simd_distance(b, c), simd_distance(a, c)) / spacing)))
            for i in 0...n {
                for j in 0...(n - i) {
                    let u = Double(i) / Double(n), v = Double(j) / Double(n)
                    add(a + (b - a) * u + (c - a) * v)
                }
            }
        }
    }

    private func key(_ p: SIMD3<Double>) -> SIMD3<Int32> { SIMD3<Int32>(Int32(floor(p.x / cell)), Int32(floor(p.y / cell)), Int32(floor(p.z / cell))) }

    private func add(_ p: SIMD3<Double>) {
        let k = key(p)
        // um ponto a cada ~cell/3 por célula basta para a folga
        if let list = cells[k], list.contains(where: { simd_distance_squared($0, p) < (cell / 3) * (cell / 3) }) { return }
        cells[k, default: []].append(p)
        pointCount += 1
        boxMin = simd_min(boxMin, p); boxMax = simd_max(boxMax, p)
    }

    /// Menor folga entre as cápsulas e a peça, procurando até `limit` mm de distância.
    public func clearance(_ caps: [Capsule], limit: Double = 300) -> Double {
        var best = limit
        for c in caps {
            let lo = c.boxMin - SIMD3(repeating: best), hi = c.boxMax + SIMD3(repeating: best)
            if simd_reduce_max(lo - boxMax) > 0 || simd_reduce_max(boxMin - hi) > 0 { continue }
            let k0 = key(simd_max(lo, boxMin)), k1 = key(simd_min(hi, boxMax))
            if k1.x < k0.x || k1.y < k0.y || k1.z < k0.z { continue }
            for x in k0.x...k1.x {
                for y in k0.y...k1.y {
                    for z in k0.z...k1.z {
                        guard let pts = cells[SIMD3(x, y, z)] else { continue }
                        for p in pts {
                            let d = RobotGeometry.pointSegmentDistance(p, c.a, c.b) - c.r
                            if d < best { best = d }
                        }
                    }
                }
            }
        }
        return best
    }
}
