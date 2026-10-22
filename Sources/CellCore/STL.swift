import Foundation
import simd

public enum STLError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let s) = self { return s }; return nil }
}

/// Leitor de STL binário e ASCII (unidades em mm, como os STL da pasta 3D Claude).
public enum STL {
    public static func load(_ url: URL) throws -> Mesh {
        let data = try Data(contentsOf: url)
        guard data.count >= 84 else { throw STLError.invalid("Arquivo STL muito pequeno") }
        let count = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 80, as: UInt32.self) }
        if 84 + Int(count) * 50 == data.count { return binary(data, Int(count)) }
        guard let text = String(data: data, encoding: .ascii) ?? String(data: data, encoding: .utf8), text.contains("vertex") else {
            throw STLError.invalid("Formato STL não reconhecido")
        }
        return ascii(text)
    }

    static func binary(_ data: Data, _ n: Int) -> Mesh {
        var pos = [SIMD3<Float>](); pos.reserveCapacity(n * 3)
        data.withUnsafeBytes { raw in
            for t in 0..<n {
                let o = 84 + t * 50 + 12
                for v in 0..<3 {
                    let b = o + v * 12
                    pos.append(SIMD3(raw.loadUnaligned(fromByteOffset: b, as: Float.self),
                                     raw.loadUnaligned(fromByteOffset: b + 4, as: Float.self),
                                     raw.loadUnaligned(fromByteOffset: b + 8, as: Float.self)))
                }
            }
        }
        return Mesh(positions: pos, indices: (0..<UInt32(pos.count)).map { $0 }).welded()
    }

    static func ascii(_ text: String) -> Mesh {
        var pos = [SIMD3<Float>]()
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count == 4, parts[0] == "vertex", let x = Float(parts[1]), let y = Float(parts[2]), let z = Float(parts[3]) {
                pos.append(SIMD3(x, y, z))
            }
        }
        return Mesh(positions: pos, indices: (0..<UInt32(pos.count)).map { $0 }).welded()
    }

    /// Painel curvo (tipo capô) para testar a simulação sem arquivos externos.
    public static func demoPanel(width: Float = 1600, depth: Float = 1200, crown: Float = 120, height: Float = 900, resolution: Int = 60) -> Mesh {
        var pos = [SIMD3<Float>](), idx = [UInt32]()
        for j in 0...resolution {
            for i in 0...resolution {
                let u = Float(i) / Float(resolution), v = Float(j) / Float(resolution)
                let x = (u - 0.5) * width, y = (v - 0.5) * depth
                let z = height + crown * (1 - powf(2 * u - 1, 2)) * (1 - 0.6 * powf(2 * v - 1, 2))
                pos.append(SIMD3(x, y, z))
            }
        }
        let w = UInt32(resolution + 1)
        for j in 0..<UInt32(resolution) {
            for i in 0..<UInt32(resolution) {
                let a = j * w + i
                idx += [a, a + 1, a + w + 1, a, a + w + 1, a + w]
            }
        }
        return Mesh(positions: pos, indices: idx)
    }
}

public extension STL {
    /// Grava malhas (já nas posições do mundo, mm) num único STL binário.
    static func writeBinary(_ meshes: [(positions: [SIMD3<Float>], indices: [UInt32])], to url: URL, header: String = "CellStudio") throws {
        var tris: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
        for m in meshes {
            for t in stride(from: 0, to: m.indices.count - 2, by: 3) {
                tris.append((m.positions[Int(m.indices[t])], m.positions[Int(m.indices[t + 1])], m.positions[Int(m.indices[t + 2])]))
            }
        }
        var d = Data(count: 80)
        d.replaceSubrange(0..<min(80, header.utf8.count), with: Array(header.utf8.prefix(80)))
        var n = UInt32(tris.count).littleEndian
        d.append(Data(bytes: &n, count: 4))
        for (a, b, c) in tris {
            let nr = simd_normalize(simd_cross(b - a, c - a))
            for v in [nr.x.isNaN ? 0 : nr.x, nr.y.isNaN ? 0 : nr.y, nr.z.isNaN ? 0 : nr.z, a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z] {
                var f = v.bitPattern.littleEndian
                d.append(Data(bytes: &f, count: 4))
            }
            d.append(contentsOf: [0, 0])
        }
        try d.write(to: url)
    }
}
