import Foundation
import simd

public typealias Vec3 = SIMD3<Double>
public typealias Mat4 = simd_double4x4

@inlinable public func deg(_ r: Double) -> Double { r * 180 / .pi }
@inlinable public func rad(_ d: Double) -> Double { d * .pi / 180 }

public extension Mat4 {
    static let identity = matrix_identity_double4x4

    static func translation(_ t: Vec3) -> Mat4 {
        var m = Mat4.identity
        m.columns.3 = SIMD4(t.x, t.y, t.z, 1)
        return m
    }

    static func rotX(_ a: Double) -> Mat4 {
        let c = cos(a), s = sin(a)
        return Mat4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, c, s, 0), SIMD4(0, -s, c, 0), SIMD4(0, 0, 0, 1)))
    }

    static func rotY(_ a: Double) -> Mat4 {
        let c = cos(a), s = sin(a)
        return Mat4(columns: (SIMD4(c, 0, -s, 0), SIMD4(0, 1, 0, 0), SIMD4(s, 0, c, 0), SIMD4(0, 0, 0, 1)))
    }

    static func rotZ(_ a: Double) -> Mat4 {
        let c = cos(a), s = sin(a)
        return Mat4(columns: (SIMD4(c, s, 0, 0), SIMD4(-s, c, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)))
    }

    var position: Vec3 { Vec3(columns.3.x, columns.3.y, columns.3.z) }
    var xAxis: Vec3 { Vec3(columns.0.x, columns.0.y, columns.0.z) }
    var yAxis: Vec3 { Vec3(columns.1.x, columns.1.y, columns.1.z) }
    var zAxis: Vec3 { Vec3(columns.2.x, columns.2.y, columns.2.z) }

    var rotation: simd_double3x3 {
        simd_double3x3(columns: (xAxis, yAxis, zAxis))
    }
}

/// Pose cartesiana na convenção da Dürr (Matrix4x4.ComputeKardanTcp do DXQ):
/// X/Y/Z em mm, A/B/C em graus, R = Rz(C) · Ry(B) · Rx(A) — A gira em torno de X e C em torno de Z.
/// (A KUKA usa o inverso: A em torno de Z, C em torno de X; ver KRL.)
public struct Pose: Codable, Equatable, Hashable {
    public var x, y, z, a, b, c: Double

    public init(x: Double = 0, y: Double = 0, z: Double = 0, a: Double = 0, b: Double = 0, c: Double = 0) {
        self.x = x; self.y = y; self.z = z; self.a = a; self.b = b; self.c = c
    }

    public var position: Vec3 { Vec3(x, y, z) }

    public var matrix: Mat4 {
        Mat4.translation(position) * Mat4.rotZ(rad(c)) * Mat4.rotY(rad(b)) * Mat4.rotX(rad(a))
    }

    public init(matrix m: Mat4) {
        let r = m.rotation
        // r[col][row]
        let r20 = r[0][2], r21 = r[1][2], r22 = r[2][2], r10 = r[0][1], r00 = r[0][0]
        let bRad = atan2(-r20, sqrt(r00 * r00 + r10 * r10))
        var aRad: Double, cRad: Double
        if abs(cos(bRad)) > 1e-9 {
            cRad = atan2(r10, r00)
            aRad = atan2(r21, r22)
        } else {
            cRad = atan2(-r[1][0], r[1][1])
            aRad = 0
        }
        self.init(x: m.columns.3.x, y: m.columns.3.y, z: m.columns.3.z, a: deg(aRad), b: deg(bRad), c: deg(cRad))
    }

    public static func lerp(_ p: Pose, _ q: Pose, _ t: Double) -> Pose {
        let qa = simd_quatd(p.matrix.rotation), qb = simd_quatd(q.matrix.rotation)
        let qr = simd_slerp(qa, qb, t)
        let pos = p.position + (q.position - p.position) * t
        var m = Mat4(qr)
        m.columns.3 = SIMD4(pos.x, pos.y, pos.z, 1)
        return Pose(matrix: m)
    }
}

/// Vetor de rotação (eixo * ângulo) que leva R1 a R2, usado no erro de orientação da cinemática inversa.
func rotationError(from r1: simd_double3x3, to r2: simd_double3x3) -> Vec3 {
    let re = r2 * r1.transpose
    let q = simd_quatd(re)
    let angle = q.angle
    if angle < 1e-12 { return .zero }
    let a = angle > .pi ? angle - 2 * .pi : angle
    return simd_normalize(q.axis) * a
}
