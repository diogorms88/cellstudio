import Foundation
import simd

/// Decodificador da compressão "edgebreaker" usada nos shells HSF (esquema 2, pontos esquema 2/3).
/// Conectividade: operações C/L/E/R/S sobre um laço de fronteira; pontos: previsão por paralelogramo
/// com resíduos em códigos de comprimento variável (cascata 2/6/10/…/31 bits).
enum Edgebreaker {
    static let none = Int(Int32(bitPattern: 0x8080_8080))
    static let dummy = Int(Int32(bitPattern: 0x8000_0003))
    static let cascadeResidual = [2, 6, 10, 14, 18, 22, 26, 31]
    static let cascadeCount = [16, 31]

    struct Result {
        var points: [SIMD3<Float>]
        var triangles: [UInt32]
        var pointCount: Int
    }

    struct MTable {
        var flags = 0
        var mlengths: [Int] = []
        var dummies: [Int] = []
        var patches: [Int: Int] = [:]
        var bbox: [Float]?
        var quant = [11, 11, 11]
    }

    static func int32(_ b: [UInt8], _ o: Int) -> Int {
        Int(Int32(bitPattern: UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24))
    }

    static func decode(_ blob: [UInt8]) throws -> Result {
        guard blob.count >= 24 else { throw HSFError(message: "edgebreaker curto") }
        let scheme = Int(blob[0])
        guard scheme >= 2 else { throw HSFError(message: "edgebreaker esquema \(scheme) não suportado") }
        let opsLen = int32(blob, 4), mtLen = int32(blob, 8), pLen = int32(blob, 12), nPts = int32(blob, 16)
        let hdr = scheme == 0 ? 0x14 : 0x18
        guard hdr + opsLen <= blob.count else { throw HSFError(message: "edgebreaker inválido") }
        let ops = Array(blob[hdr..<(hdr + opsLen)])
        var o = hdr + opsLen
        o += (4 - o % 4) % 4
        let mt = try parseMTable(blob, o)
        o += mtLen
        o += (4 - o % 4) % 4
        guard o + pLen <= blob.count else { throw HSFError(message: "pontos edgebreaker fora do bloco") }
        let pdata = Array(blob[o..<(o + pLen)])

        var (cv, co, faces, nv) = try connectivity(ops, mt)
        compact(nv, mt, &cv, &faces)
        guard let bbox = mt.bbox else { throw HSFError(message: "edgebreaker sem caixa de quantização") }
        let ipts = decodePoints(cv, co, nPts, pdata)
        // desquantização
        var pts = [SIMD3<Float>](repeating: .zero, count: nPts)
        for k in 0..<3 {
            let mx = (1 << mt.quant[k]) - 1
            let lo = bbox[k], hi = bbox[k + 3]
            let step = hi == lo ? 0 : (hi - lo) / Float(mx)
            for i in 0..<nPts {
                let q = ipts[i * 3 + k]
                pts[i][k] = q == mx ? hi : lo + Float(q) * step
            }
        }
        var tris = [UInt32]()
        tris.reserveCapacity(faces.count)
        for t in stride(from: 0, to: faces.count - 2, by: 3) {
            let a = faces[t], b = faces[t + 1], c = faces[t + 2]
            if a >= 0, b >= 0, c >= 0, a < nPts, b < nPts, c < nPts { tris += [UInt32(a), UInt32(b), UInt32(c)] }
        }
        return Result(points: pts, triangles: tris, pointCount: nPts)
    }

    static func parseMTable(_ b: [UInt8], _ start: Int) throws -> MTable {
        var o = start
        func rd() throws -> Int {
            guard o + 4 <= b.count else { throw HSFError(message: "mtable truncada") }
            defer { o += 4 }
            return int32(b, o)
        }
        var m = MTable()
        m.flags = try rd()
        let f = m.flags
        let nLen = f & 1 != 0 ? try rd() : 0
        let nM2 = f & 2 != 0 ? try rd() : 0
        let nDum = f & 8 != 0 ? try rd() : 0
        let nPat = f & 0x10 != 0 ? try rd() : 0
        for _ in 0..<nLen { m.mlengths.append(try rd()) }
        for _ in 0..<(2 * nM2) { _ = try rd() }
        var prev = 0
        for _ in 0..<nDum { prev += try rd(); m.dummies.append(prev) }
        prev = 0
        for _ in 0..<(nPat / 2) {
            let old = try rd() + prev
            let new = try rd()
            m.patches[old] = new
            prev = old
        }
        if f & 0x20 != 0 {
            var bb = [Float]()
            for _ in 0..<6 { bb.append(Float(bitPattern: UInt32(truncatingIfNeeded: try rd()))) }
            m.bbox = bb
        }
        if f & 0x40 != 0 { m.quant = [try rd(), try rd(), try rd()] }
        return m
    }

    /// Pré-varredura de um componente: comprimento inicial da fronteira e deslocamentos dos S.
    static func prescan(_ ops: [UInt8], _ start: Int, _ mt: MTable) throws -> (Int, [Int: Int]) {
        var length = 0, sCount = 0, mi = 0
        var sStack: [Int] = [], lStack: [Int] = []
        var offsets: [Int: Int] = [:]
        var i = start
        while i < ops.count {
            switch ops[i] {
            case 0: length -= 1
            case 1, 3: length += 1
            case 2:
                length += 3
                if lStack.isEmpty { return (length, offsets) }
                let s = sStack.removeLast(), t = lStack.removeLast()
                offsets[s] = length - t - 2
            case 4:
                sStack.append(sCount); lStack.append(length - 1); sCount += 1; length -= 1
            case 5:
                guard mi < mt.mlengths.count else { throw HSFError(message: "edgebreaker M sem comprimento") }
                length += -1 - mt.mlengths[mi]; mi += 1
            default:
                throw HSFError(message: "edgebreaker operação \(ops[i]) não suportada")
            }
            i += 1
        }
        return (length, offsets)
    }

    static func connectivity(_ ops: [UInt8], _ mt: MTable) throws -> ([Int], [Int], [Int], Int) {
        var cv = [Int](), co = [Int](), faces = [Int]()
        cv.reserveCapacity(ops.count * 3); co.reserveCapacity(ops.count * 3); faces.reserveCapacity(ops.count * 3)
        var nv = 0, pos = 0
        while pos < ops.count {
            let (loop, offsets) = try prescan(ops, pos, mt)
            guard loop >= 1 else { throw HSFError(message: "edgebreaker laço inválido") }
            let cap = loop + ops.count * 2 + 8
            var next = [Int](repeating: 0, count: cap), prev = next, vid = next
            var ref = [Int](repeating: none, count: cap)
            for k in 0..<loop { prev[k] = k - 1; next[k] = k + 1; vid[k] = nv; nv += 1 }
            prev[0] = loop - 1; next[loop - 1] = 0
            var free: [Int] = [], freeNext = loop
            var sStack: [Int] = [], si = 0
            var g = 0, done = false
            while !done {
                guard pos < ops.count else { throw HSFError(message: "edgebreaker terminou no meio") }
                let c = cv.count
                cv += [0, 0, 0]; co += [none, none, none]
                let a = vid[g], b = vid[next[g]]
                if free.isEmpty {
                    guard freeNext < cap else { throw HSFError(message: "edgebreaker sem espaço") }
                    free.append(freeNext); freeNext += 1
                }
                let r0 = ref[g]
                if r0 != none { co[r0] = c }
                co[c] = r0
                cv[c] = a; cv[c + 1] = b
                let op = ops[pos]; pos += 1
                let third: Int
                switch op {
                case 0: // C
                    third = nv
                    let n = free.removeLast(), p = prev[g]
                    next[p] = n; prev[n] = p; next[n] = g; prev[g] = n
                    vid[n] = vid[g]; vid[g] = nv
                    ref[g] = c + 1; ref[n] = c + 2
                    nv += 1
                case 1: // L
                    let p = prev[g]
                    third = vid[p]
                    let r2 = ref[p]
                    co[c + 2] = r2
                    if r2 != none { co[r2] = c + 2 }
                    vid[g] = vid[p]
                    free.append(p)
                    let pp = prev[p]; prev[g] = pp; next[pp] = g
                    ref[g] = c + 1
                case 2: // E
                    let p = prev[g], n = next[g]
                    third = vid[p]
                    let r1 = ref[n]; co[c + 1] = r1
                    if r1 != none { co[r1] = c + 1 }
                    let r2 = ref[p]; co[c + 2] = r2
                    if r2 != none { co[r2] = c + 2 }
                    free += [g, p, n]
                    if sStack.isEmpty { done = true } else { g = sStack.removeLast() }
                case 3: // R
                    let n = next[g], nn = next[n]
                    third = vid[nn]
                    let r1 = ref[n]; co[c + 1] = r1
                    if r1 != none { co[r1] = c + 1 }
                    free.append(n)
                    next[g] = nn; prev[nn] = g
                    ref[g] = c + 2
                case 4: // S
                    guard let off = offsets[si] else { throw HSFError(message: "edgebreaker S sem deslocamento") }
                    si += 1
                    var s = g
                    for _ in 0...max(off, 0) { s = next[s] }
                    let ns = next[s]
                    third = vid[ns]
                    let n = free.removeLast()
                    sStack.append(n)
                    let p = prev[g]
                    next[p] = n; prev[n] = p; next[n] = ns; prev[ns] = n
                    ref[n] = c + 2; vid[n] = vid[g]; vid[g] = vid[ns]; ref[g] = c + 1
                    prev[g] = s; next[s] = g
                default:
                    throw HSFError(message: "edgebreaker operação \(op)")
                }
                cv[c + 2] = third
                if a == b || b == third || third == a { throw HSFError(message: "edgebreaker triângulo degenerado") }
                faces += [a, b, third]
            }
        }
        return (cv, co, faces, nv)
    }

    /// Remove vértices fictícios e aplica os "patches" (vértices unidos), renumerando.
    static func compact(_ nv: Int, _ mt: MTable, _ cv: inout [Int], _ faces: inout [Int]) {
        guard !mt.dummies.isEmpty || !mt.patches.isEmpty else { return }
        let D = Int.min, P = Int.min + 1
        var dst = [Int](repeating: 0, count: nv)
        for d in mt.dummies where d >= 0 && d < nv { dst[d] = D }
        for old in mt.patches.keys where old >= 0 && old < nv { dst[old] = P }
        var k = 0
        for v in 0..<nv { if dst[v] == D || dst[v] == P { k += 1 } else { dst[v] = k } }
        func remap(_ v: Int) -> Int {
            guard v >= 0, v < nv else { return v }
            switch dst[v] {
            case D: return dummy
            case P: return mt.patches[v] ?? dummy
            default: return v - dst[v]
            }
        }
        var f2 = [Int]()
        f2.reserveCapacity(faces.count)
        for t in stride(from: 0, to: faces.count - 2, by: 3) {
            let a = faces[t], b = faces[t + 1], c = faces[t + 2]
            if dst[a] == D || dst[b] == D || dst[c] == D { continue }
            f2 += [remap(a), remap(b), remap(c)]
        }
        faces = f2
        cv = cv.map(remap)
    }

    @inline(__always) static func nxt(_ c: Int) -> Int { (c / 3) * 3 + (c + 1) % 3 }
    @inline(__always) static func prv(_ c: Int) -> Int { (c / 3) * 3 + (c + 2) % 3 }

    /// Reconstrói as posições quantizadas (inteiros) percorrendo a malha por previsão de paralelogramo.
    static func decodePoints(_ cv: [Int], _ co: [Int], _ nPts: Int, _ data: [UInt8]) -> [Int] {
        var bits = BitReader(data)
        _ = bits.cascade(cascadeResidual)          // há faixas de triângulos? (não usado)
        let nAbs = bits.cascade(cascadeCount)
        let nRes = bits.cascade(cascadeCount)
        var absP = [Int](repeating: 0, count: max(nAbs, 0) * 3)
        for i in 0..<absP.count { absP[i] = bits.cascade(cascadeCount) }
        var res = [Int](repeating: 0, count: max(nRes, 0) * 3)
        for i in 0..<res.count { res[i] = bits.cascade(cascadeResidual) }

        var pts = [Int](repeating: 0, count: nPts * 3)
        var seen = [Bool](repeating: false, count: nPts)
        var ai = 0, ri = 0
        var stack: [Int] = []
        func valid(_ v: Int) -> Bool { v >= 0 && v < nPts }
        for c in 0..<cv.count {
            let v = cv[c]
            guard valid(v), !seen[v], valid(cv[nxt(c)]), valid(cv[prv(c)]) else { continue }
            stack.removeAll(keepingCapacity: true)
            var k = c
            for _ in 0..<3 {
                let vk = cv[k]
                if valid(vk) && !seen[vk] && ai < nAbs {
                    seen[vk] = true
                    pts[vk * 3] = absP[ai * 3]; pts[vk * 3 + 1] = absP[ai * 3 + 1]; pts[vk * 3 + 2] = absP[ai * 3 + 2]
                    ai += 1
                }
                if co[k] >= 0 { stack.append(k) }
                k = nxt(k)
            }
            while let k = stack.popLast() {
                let c2 = co[k]
                guard c2 >= 0 else { continue }
                let u = cv[prv(c2)]
                guard valid(u), !seen[u] else { continue }
                let va = cv[c2], vb = cv[nxt(c2)]
                let oc = co[c2]
                guard oc >= 0, valid(va), valid(vb), ri < nRes else { continue }
                let vc = cv[prv(oc & 0x7fff_ffff)]
                guard valid(vc) else { continue }
                for d in 0..<3 {
                    pts[u * 3 + d] = pts[vb * 3 + d] - pts[vc * 3 + d] + pts[va * 3 + d] - res[ri * 3 + d]
                }
                ri += 1
                let n1 = nxt(c2)
                if co[n1] >= 0 { stack.append(n1) }
                let n2 = nxt(n1)
                if co[n2] >= 0 { stack.append(n2) }
                seen[u] = true
            }
        }
        return pts
    }
}
