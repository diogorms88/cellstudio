import zlib
import Foundation
import simd

// Leitor de HOOPS Stream Files (.hsf) usados pelo DXQ3D.onsite para os modelos 3D
// (robôs, trilhos, ferramentas). Implementação própria, a partir da análise do formato
// (especificação pública do HSF + engenharia reversa para interoperabilidade dos trechos
// não documentados: byte "general" (V ≥ 19.75), edgebreaker esquema 2, inteiros triviais).
//
// O que é lido: segmentos, matrizes, cores, visibilidade, tags, referências, instâncias e
// shells (pontos quantizados + faixas de triângulos, ou edgebreaker). Atributos de
// renderização, linhas e textos são pulados.

public struct HSFPart {
    public var positions: [SIMD3<Float>]   // metros, no sistema do arquivo
    public var indices: [UInt32]           // triângulos
    public var color: SIMD3<Float>?        // 0…1
}

public struct HSFError: Error, LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

public enum HSF {
    /// Motivo da última leitura parcial (diagnóstico).
    public static var lastWarning: String?

    /// Lê o arquivo e devolve as malhas visíveis já transformadas para o sistema do arquivo.
    public static func load(_ url: URL) throws -> [HSFPart] {
        let data = try Data(contentsOf: url)
        return try parse(data)
    }

    /// Translação do segmento raiz do arquivo (o DXQ usa a do K1 como "root offset" do trilho).
    public static func rootTranslation(_ data: Data) -> SIMD3<Float> {
        guard let (version, body) = try? decompress([UInt8](data)) else { return .zero }
        let ctx = Context(version: version)
        var r = ByteReader(body)
        while !r.atEnd && !ctx.done {
            if (try? step(&r, ctx)) == nil { break }
            if ctx.root.matrix != matrix_identity_float4x4 || ctx.stack.count > 2 { break }
        }
        let c = ctx.root.matrix.columns.3
        return SIMD3(c.x, c.y, c.z)
    }

    public static func parse(_ data: Data) throws -> [HSFPart] {
        let bytes = [UInt8](data)
        let (version, body) = try decompress(bytes)
        let ctx = Context(version: version)
        var r = ByteReader(body)
        while !r.atEnd && !ctx.done {
            do { try step(&r, ctx) } catch {
                // mantém a geometria lida até aqui (ex.: polilinhas no fim do arquivo)
                ctx.warning = "\(error)"
                break
            }
        }
        ctx.finish()
        lastWarning = ctx.warning
        return ctx.flatten()
    }

    // MARK: Cabeçalho e descompressão

    static func decompress(_ d: [UInt8]) throws -> (Int, [UInt8]) {
        guard d.count > 16, String(bytes: d[0..<8], encoding: .ascii) == ";; HSF V" else { throw HSFError(message: "não é um arquivo HSF") }
        var i = 8
        var vs = ""
        while i < d.count, d[i] != 0x20, d[i] != 0x0a { vs.append(Character(UnicodeScalar(d[i]))); i += 1 }
        let version = Int(((Double(vs) ?? 0) * 100).rounded())
        while i < d.count, d[i] != 0x0a { i += 1 }
        i += 1
        while i < d.count {
            let op = d[i]; i += 1
            switch op {
            case 0x49: i += 4                                           // 'I' file info
            case 0x14:                                                  // miniatura
                let fmt = Int(d[i]), w = d[i + 1] == 0 ? 256 : Int(d[i + 1]), h = d[i + 2] == 0 ? 256 : Int(d[i + 2])
                i += 3 + w * h * (fmt == 0 ? 3 : fmt == 1 ? 4 : 1)
            case 0x42:                                                  // 'B' bounding info
                let dbl = d[i] & 1 != 0; i += 1
                let cube = d[i] == 0; i += 1
                i += (cube ? 6 : 4) * (dbl ? 8 : 4)
            case 0x3b: while i < d.count, d[i] != 0x0a { i += 1 }; i += 1 // comentário
            case 0x5a:                                                  // 'Z' início da compressão (zlib)
                // podem existir vários blocos zlib separados por opcodes crus (pausas, dicionário)
                var body = [UInt8]()
                var pos = i
                while true {
                    guard let (out, used) = inflateStream(d, from: pos) else { break }
                    body += out
                    pos += used
                    var k = pos, next = -1
                    while k + 2 < d.count {
                        if d[k] == 0x5a && d[k + 1] == 0x78 && ((Int(d[k + 1]) << 8) | Int(d[k + 2])) % 31 == 0 { next = k; break }
                        k += 1
                    }
                    if next < 0 { break }
                    // Pausas e aberturas/fechamentos de segmentos podem ficar fora
                    // do zlib. Preservá-los mantém a biblioteca de includes oculta.
                    body.append(contentsOf: d[pos..<next])
                    pos = next + 1
                }
                if body.isEmpty { throw HSFError(message: "falha ao descompactar") }
                return (version, body)
            default:
                return (version, Array(d[(i - 1)...]))
            }
        }
        return (version, [])
    }

    /// Descompacta um bloco zlib começando em `start`; devolve os dados e quantos bytes de entrada usou.
    static func inflateStream(_ d: [UInt8], from start: Int) -> ([UInt8], Int)? {
        guard start + 2 < d.count, d[start] == 0x78, d.count - start <= Int(UInt32.max) else { return nil }
        // zlib informa o fim exato do bloco. O decoder deflate de Compression pode
        // consumir bytes do próximo bloco ao antecipar a leitura e perder geometria.
        var stream = z_stream()
        guard inflateInit_(&stream, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var out: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 1 << 18)
        let ok = d.withUnsafeBufferPointer { input -> Bool in
            stream.next_in = UnsafeMutablePointer(mutating: input.baseAddress! + start)
            stream.avail_in = UInt32(d.count - start)
            while true {
                let status = buffer.withUnsafeMutableBufferPointer { output -> Int32 in
                    stream.next_out = output.baseAddress!
                    stream.avail_out = UInt32(output.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                out.append(contentsOf: buffer.prefix(buffer.count - Int(stream.avail_out)))
                if status == Z_STREAM_END { return true }
                if status != Z_OK || (stream.avail_in == 0 && stream.avail_out != 0) { return false }
            }
        }
        return ok ? (out, Int(stream.total_in)) : nil
    }

    // MARK: Leitura de bytes

    struct ByteReader {
        let b: [UInt8]
        var i = 0
        init(_ b: [UInt8]) { self.b = b }
        var atEnd: Bool { i >= b.count }

        mutating func need(_ n: Int) throws { if n < 0 || i + n > b.count { throw HSFError(message: "fim inesperado em \(i)") } }
        mutating func u8() throws -> Int { try need(1); defer { i += 1 }; return Int(b[i]) }
        mutating func u16() throws -> Int { try need(2); defer { i += 2 }; return Int(b[i]) | Int(b[i + 1]) << 8 }
        mutating func u32() throws -> UInt32 {
            try need(4); defer { i += 4 }
            return UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
        }
        mutating func i32() throws -> Int { Int(Int32(bitPattern: try u32())) }
        mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
        mutating func floats(_ n: Int) throws -> [Float] { try need(n * 4); return try (0..<n).map { _ in try f32() } }
        mutating func skip(_ n: Int) throws { try need(n); i += n }
        mutating func bytes(_ n: Int) throws -> ArraySlice<UInt8> { try need(n); defer { i += n }; return b[i..<(i + n)] }
        mutating func varInt() throws -> Int {
            var v = try u8(), full = v, shift = 8
            while v & 0x80 != 0 { v = try u8(); full |= v << shift; shift += 8 }
            return full
        }
    }

    // MARK: Árvore de segmentos

    final class Node {
        var name = ""
        var matrix: simd_float4x4 = matrix_identity_float4x4
        var color: SIMD3<Float>?
        var facesVisible: Bool?
        var children: [Node] = []
        var shell: Shell?
        var refIndex: Int?
        var refMatrix: simd_float4x4?
        var isSegment = false
        weak var parent: Node?
        var includePath: String?
        weak var includeFrom: Node?
        var stylePath: String?

        func child(_ n: String) -> Node? {
            guard !n.isEmpty else { return nil }
            return children.first { $0.isSegment && $0.name == n }
        }
    }

    static func newSegment(_ name: String, _ parent: Node) -> Node {
        let n = Node()
        n.isSegment = true
        n.name = name
        n.parent = parent
        parent.children.append(n)
        return n
    }

    /// Resolve um caminho de segmento HOOPS (relativo com "..", absoluto "/" ou da biblioteca "?…").
    static func resolve(_ root: Node, _ cur: Node, _ path: String, create: Bool) -> Node? {
        var node: Node
        var parts: [String]
        if path.hasPrefix("/") {
            node = root; parts = path.dropFirst().split(separator: "/").map(String.init)
        } else if path.hasPrefix("?") {
            node = root; parts = path.split(separator: "/").map(String.init)
        } else {
            node = cur; parts = path.split(separator: "/").map(String.init)
        }
        for p in parts {
            if p == ".." { node = node.parent ?? node; continue }
            if p == "." || p.isEmpty { continue }
            if let n = node.child(p) { node = n }
            else if create { node = newSegment(p, node) }
            else { return nil }
        }
        return node
    }

    struct Shell {
        var points: [SIMD3<Float>]
        var triangles: [UInt32]
        var lod: Int
    }

    final class Context {
        let version: Int
        let root = Node()
        var stack: [Node]
        var tags: [Node?] = []
        var lastObj: Node?
        var refinements: [(Int, Shell)] = []
        var instances: [(Int, Int, [Float])] = []
        var geoAttr = false
        var lastRef: Node?
        var done = false
        var warning: String?
        let probe: Bool

        init(version: Int, probe: Bool = false) {
            self.version = version
            self.probe = probe
            root.isSegment = true
            stack = [root]
        }

        func finish() {
            for (idx, s) in refinements where idx >= 0 && idx < tags.count {
                tags[idx]?.shell = s
            }
            for (from, to, m) in instances {
                guard from >= 0, from < tags.count, to >= 0, to < tags.count,
                      let src = tags[from]?.shell, let dst = tags[to] else { continue }
                let M = hoopsColumnMatrix(m)
                dst.shell = Shell(points: src.points.map { transform($0, M) }, triangles: src.triangles, lod: src.lod)
            }
        }

        func flatten() -> [HSFPart] {
            var out: [HSFPart] = []
            func emit(_ s: Shell, _ M: simd_float4x4, _ c: SIMD3<Float>?) {
                guard s.lod == 0, !s.triangles.isEmpty else { return }
                out.append(HSFPart(positions: s.points.map { transform($0, M) }, indices: s.triangles, color: c))
            }
            func walk(_ n: Node, _ parent: simd_float4x4, _ color: SIMD3<Float>?, _ visible: Bool, _ depth: Int, included: Bool = false) {
                guard depth < 48 else { return }
                if n.name.hasPrefix("?") && !included { return }   // biblioteca de include: só por referência
                // vetor-linha (HOOPS): p' = p · M_filho · M_pai → em coluna: M_pai · M_filho
                let M = parent * n.matrix
                var c = n.color ?? color
                if n.color == nil, let sp = n.stylePath, let st = HSF.resolve(root, n, sp, create: false), let sc = st.color { c = sc }
                let vis = n.facesVisible ?? visible
                for ch in n.children {
                    if ch.isSegment { walk(ch, M, c, vis, depth + 1) }
                    else if let ip = ch.includePath, vis, let from = ch.includeFrom,
                            let t = HSF.resolve(root, from, ip, create: false), t !== n {
                        walk(t, M, c, true, depth + 1, included: true)
                    }
                    else if let s = ch.shell, vis { emit(s, M, c) }
                    else if let ri = ch.refIndex, vis, ri >= 0, ri < tags.count, let t = tags[ri] {
                        let M3 = ch.refMatrix.map { M * $0 } ?? M
                        if let s = t.shell { emit(s, M3, c) }
                        else if t.isSegment {
                            let saved = t.facesVisible
                            t.facesVisible = true
                            walk(t, M3, c, true, depth + 1)
                            t.facesVisible = saved
                        }
                    }
                }
            }
            walk(root, matrix_identity_float4x4, nil, true, 0)
            return out
        }
    }

    static func transform(_ p: SIMD3<Float>, _ M: simd_float4x4) -> SIMD3<Float> {
        let v = M * SIMD4(p, 1)
        return SIMD3(v.x, v.y, v.z)
    }

    // MARK: Opcodes

    static let validOps: Set<UInt8> = Set(Array("()%}m\"~U-qS<{VHJ?zs:r&!hlLg".utf8) + [0x00, 0x01, 0x18, 0x1a, 0x51, 0x78])

    /// HSF 23 acrescenta bytes de CRC após os operandos de determinados opcodes.
    /// Quantidade derivada de BBaseOpcodeHandler.selector/GetCRC do toolkit nativo.
    static func crcSize(_ length: Int) -> Int {
        let n = abs(length)
        return n < 64 ? 1 : n < 1024 ? 2 : n < 16384 ? 3 : 4
    }

    static func step(_ r: inout ByteReader, _ c: Context) throws {
        var crcBytes = 0
        let op = UInt8(try r.u8())
        let ch = Character(UnicodeScalar(op))
        if ch != "%" && ch != ":" { c.geoAttr = c.geoAttr && (ch == "\"" || ch == "~" || ch == "V") }
        if !"r%:\"~V".contains(ch) { c.lastRef = nil }
        let top = c.stack[c.stack.count - 1]
        switch ch {
        case "(":
            var n = try r.u8()
            if n == 255 { n = Int(try r.u32()) }
            crcBytes = crcSize(n)
            let name = String(decoding: try r.bytes(n), as: UTF8.self)
            let seg: Node
            if name.contains("/") || name.hasPrefix("..") || name.hasPrefix("?") {
                seg = resolve(c.root, top, name, create: true) ?? newSegment(name, top)
            } else {
                seg = (name.isEmpty ? nil : top.child(name)) ?? newSegment(name, top)
            }
            c.stack.append(seg); c.lastObj = seg
        case ")":
            if c.stack.count > 1 { c.lastObj = c.stack.removeLast() }
        case "\u{0}", "\u{1}":
            break
        case "%":
            crcBytes = 1
            _ = try r.u8()
            let m = try r.floats(12)
            if c.geoAttr, let ref = c.lastRef { ref.refMatrix = hoopsColumnMatrix(m) } else { top.matrix = hoopsColumnMatrix(m) }
        case "}":
            let proj = try r.u8(); _ = try r.u8(); try r.skip(44)
            for bit in [0x10, 0x20, 0x40] where proj & bit != 0 { try r.skip(4) }
            try r.skip(try r.u8())
        case "m":
            let n = Int(try r.u32())
            if n > 100_000 { throw HSFError(message: "m inválido") }
            crcBytes = crcSize(n)
            for _ in 0..<n { try r.skip(4); try r.skip(Int(try r.u32())) }
        case "\"":
            crcBytes = 2
            _ = try r.varInt()
            let channels = try r.varInt()
            var diffuse: SIMD3<Float>?
            for bit in 0..<16 where channels & (1 << bit) != 0 {
                if bit == 5 || bit == 6 { try r.skip(4); continue }
                let L = try r.u8()
                if L == 0 {
                    let rgb = try r.bytes(3).map { Float($0) / 255 }
                    if bit == 0 { diffuse = SIMD3(rgb[0], rgb[1], rgb[2]) }
                } else { try r.skip(L) }
            }
            if let d = diffuse { top.color = d }
        case "~":
            crcBytes = 1
            _ = try r.varInt()
            let rgb = try r.bytes(3).map { Float($0) / 255 }
            top.color = SIMD3(rgb[0], rgb[1], rgb[2])
        case "U":
            var L = try r.u16()
            if L == 0xffff { L = Int(try r.u32()) }
            crcBytes = crcSize(L)
            try r.skip(L)
        case "-":
            var L = try r.u8()
            if L == 0xff { L = try r.u8() }
            try r.skip(L)
            // HSF 23 acrescenta o CRC ao formato nomeado da linha. O byte
            // seguinte (0x9d neste hanger) é o CRC, não um novo opcode.
            crcBytes = 1
        case "q":
            c.tags.append(c.lastObj)
        case "S":
            let (idx, shell) = try readShell(&r, version: c.version)
            if let idx {
                if let s = shell { c.refinements.append((idx, s)) }
            } else {
                let obj = Node()
                obj.shell = shell
                top.children.append(obj); c.lastObj = obj
            }
        case "<", "{":
            let g = try r.u8()
            if g & 0xfc != 0 { throw HSFError(message: "referência com flags \(g)") }
            var L = try r.u8()
            if L == 0xff { L = Int(try r.u32()) }
            let path = String(decoding: try r.bytes(L), as: UTF8.self)
            if g & 1 != 0 {
                var C = try r.u8()
                if C == 0xff { C = Int(try r.u32()) }
                try r.skip(C)
            }
            if g & 2 != 0 { throw HSFError(message: "lock masks") }
            if ch == "<" {
                let inc = Node()
                inc.includePath = path
                inc.includeFrom = top
                top.children.append(inc)
            } else {
                top.stylePath = path
            }
        case "z":
            break
        case "s":
            let idx = try r.i32()
            if c.probe {
                let n = Node(); n.isSegment = true; c.stack.append(n)
            } else {
                if idx >= 0, idx < c.tags.count, let seg = c.tags[idx], seg.isSegment {
                    c.stack.append(seg)
                } else {
                    // marca que não é um segmento conhecido (ex.: marcadores do DXQ no fim do Virtus.hsf):
                    // abre um segmento solto, fora da cena, para o fluxo continuar
                    let n = Node(); n.isSegment = true; c.stack.append(n)
                }
            }
        case ":":
            c.geoAttr = true
        case "r":
            let idx = try r.i32()
            var L = try r.u8()
            if L == 0xff { L = Int(try r.u32()) }
            try r.skip(L)
            crcBytes = 1
            let ref = Node()
            ref.refIndex = idx
            top.children.append(ref); c.lastRef = ref
        case "&":
            let from = try r.i32(); _ = try r.i32(); let to = try r.i32(); _ = try r.i32(); _ = try r.u8()
            c.instances.append((from, to, try r.floats(12)))
        case "!":
            let g = try r.u8()
            let w = g & 0x80 != 0 ? 2 : 1
            try r.skip(w - 1 + 5 * w)
            crcBytes = 1        // HSF 23: CRC no fim da seletividade (ex.: Virtus.hsf, 0xf1 logo depois)
        case "h":
            _ = try r.u8()
        case "R", "F":
            // R (opções de renderização) e F (fonte de texto) têm muitos campos opcionais e nenhuma geometria:
            // pula até o fluxo voltar a ser válido (ex.: Virtus.hsf traz F "sans serif" no cabeçalho de estilos)
            if c.probe { throw HSFError(message: "\(ch) no lookahead") }
            r.i = try resync(r.b, from: r.i, version: c.version)
        case "V":
            crcBytes = 1
            var m = try r.u8(), v = try r.u8()
            if m & 0x80 != 0 { m |= try r.u16() << 8; v |= try r.u16() << 8 }
            if m & 0x800000 != 0 { m |= try r.u8() << 24; v |= try r.u8() << 24 }
            if m & 1 != 0 { top.facesVisible = v & 1 != 0 }
        case "H":
            try readHeuristics(&r, c.version)
            crcBytes = 2        // HSF 23: 2 bytes de CRC (ex.: "54 7d" depois de H 02 00 00 00 no Virtus.hsf)
        case "J":
            var L = try r.u8()
            if L == 0xff { L = Int(try r.u32()) }
            try r.skip(L); try r.skip(try r.u16())
            // Line style: nome + definição. Em HSF 23 o opcode termina
            // com o CRC do objeto; sem consumi-lo, o byte seguinte aparece
            // como um opcode inválido (por exemplo 0x75).
            crcBytes = 1
        case "?":
            var L = try r.u8()
            if L == 0xff { L = Int(try r.u32()) } else if L == 0xfe { L = try r.u16() }
            crcBytes = crcSize(L)
            try r.skip(L)
        case "x":
            // texto com codificação (marcador do DXQ, ex.: "W"): opções, posição, codificação, tamanho, caracteres, opções
            _ = try r.u8(); try r.skip(12)
            _ = try r.u8()
            let n = try r.u8()
            try r.skip(n); _ = try r.u8()
            crcBytes = 1
        case "Q":
            // policilindro (marcador do DXQ): opções, pontos, raios, tampas
            _ = try r.u8()
            let n = Int(try r.i32()); guard (0...1_000_000).contains(n) else { throw HSFError(message: "policilindro inválido") }
            try r.skip(12 * n)
            let rc = Int(try r.i32()); guard (0...1_000_000).contains(rc) else { throw HSFError(message: "policilindro inválido") }
            try r.skip(4 * rc)
            _ = try r.u8()
            crcBytes = 1
        case "\u{1a}":
            // esfera (marcador do DXQ, raio 0,02 m): 2 bytes de opções, centro, raio [+ eixos]; não é geometria da peça
            _ = try r.u8()
            let simple = try r.u8() & 1 != 0          // 01: só centro e raio; 00: + eixo e orientação
            try r.skip(12 + 4)
            if !simple { try r.skip(24) }
            crcBytes = 1
        case "\u{18}":
            try r.skip(try r.i32())
        case "l":
            let g = try r.u8(); try r.skip(g & 1 != 0 ? 48 : 24)
            crcBytes = 1        // HSF 23: CRC no fim da linha (Virtus.hsf: "… 80 3f 4e" antes do ")")
        case "L", "g":
            let g = try r.u8(); let n = abs(try r.i32())
            if n > 50_000_000 { throw HSFError(message: "polilinha inválida") }
            try r.skip(n * 3 * (g & 1 != 0 ? 8 : 4))
        default:
            throw HSFError(message: String(format: "opcode 0x%02x em %d", op, r.i - 1))
        }
        if c.version >= 2300 { try r.skip(crcBytes) }
    }

    static func hoopsColumnMatrix(_ m: [Float]) -> simd_float4x4 {
        // linha i da matriz HOOPS = (m[3i], m[3i+1], m[3i+2]); p' = p · M.
        // Em vetor-coluna: p' = Mᵀ p → colunas de Mᵀ são as linhas de M.
        simd_float4x4(rows: [SIMD4(m[0], m[3], m[6], m[9]), SIMD4(m[1], m[4], m[7], m[10]),
                             SIMD4(m[2], m[5], m[8], m[11]), SIMD4(0, 0, 0, 1)])
    }

    /// O opcode R (opções de renderização) tem dezenas de campos opcionais e não traz geometria.
    /// Em vez de interpretá-lo, procura o primeiro ponto a partir do qual o fluxo volta a ser válido.
    static func resync(_ b: [UInt8], from start: Int, version: Int) throws -> Int {
        var j = start + 4
        let end = min(b.count, start + 2000)
        while j < end {
            if validOps.contains(b[j]) && lookahead(b, j, version) { return j }
            j += 1
        }
        throw HSFError(message: "não foi possível pular o opcode R")
    }

    static func lookahead(_ b: [UInt8], _ j: Int, _ version: Int, _ n: Int = 25) -> Bool {
        var r = ByteReader(b)
        r.i = j
        let ctx = Context(version: version, probe: true)
        var good = 0, strong = false
        for _ in 0..<n {
            if r.atEnd || ctx.done { return true }
            let op = b[r.i]
            // um opcode desconhecido depois de vários válidos (ex.: polilinha 0x10) ainda confirma o ponto
            guard validOps.contains(op) else { return good >= 4 && strong }
            if op == 0x28 || op == 0x29 || op == 0x53 { strong = true }
            if op == 0x28 {
                guard r.i + 1 < b.count else { return false }
                let L = Int(b[r.i + 1])
                guard r.i + 2 + L <= b.count, b[(r.i + 2)..<(r.i + 2 + L)].allSatisfy({ $0 >= 32 && $0 < 127 }) else { return false }
            }
            do { try step(&r, ctx) } catch { return false }
            good += 1
        }
        return true
    }

    static func readHeuristics(_ r: inout ByteReader, _ v: Int) throws {
        var mask = try r.u16()
        if mask & 0x8000 != 0 { mask |= try r.u16() << 16 }
        if mask & 0x8000_0000 != 0 { try r.skip(4) }
        var value = try r.u16()
        if mask & 0x8000 != 0 { value |= try r.u16() << 16 }
        if mask & 0x8000_0000 != 0 { try r.skip(4) }
        let mv = mask & value
        if mv & 0x40 != 0 { try r.skip(4) }
        if mv & 0x80 != 0 { try r.skip(4) }
        if mv & 0x0c != 0 { try r.skip(1) }
        var c = 0
        if v >= 0x2c2 && mask & 0x10000 != 0 && mv & 0x10000 != 0 { c = try r.u8() }
        if c & 0x80 != 0 { c |= try r.u8() << 8 }
        if c & 0x8000 != 0 { c |= try r.u16() << 16 }
        let big = mask & 0x10000 != 0
        if v >= 0x4b1 && big {
            if c & 2 != 0 { try r.skip(4) }
            if c & 4 != 0 { try r.skip(4) }
            if c & 0x200 != 0 { try r.skip(4) }
        }
        if mask & 0x200000 != 0 {
            let b = try r.u8()
            for i in 0..<6 where b & (1 << i) != 0 { try r.skip(4) }
        }
        if mv & 0x400000 != 0 { try r.skip(4) }
        if mask & 0x1000000 != 0 { try r.skip(1) }
        if big && c & 0x400 != 0 { try r.skip(12) }
        if big && c & 0x800 != 0 { try r.skip(4) }
        if big && c & 0x4000 != 0 { try r.skip(4) }
        if big && c & 0x10000 != 0 { try r.skip(1) }
        if mv & 0x4000000 != 0 { try r.skip(4) }
        if mv & 0x8000000 != 0 { try r.skip(1) }
        if big && c & 0x100000 != 0 { try r.skip(4) }
        if big && c & 0x400000 != 0 { try r.skip(24) }
        if mv & 0x1000_0000 != 0 { try r.skip(4) }
        if mv & 0x2000_0000 != 0 { try r.skip(2) }
        if mv & 0x4000 != 0 && v >= 0x808 { try r.skip(1) }
        if mask & 0x4000_0000 != 0 { try r.skip(2) }
    }

    // MARK: Shell

    static func readShell(_ r: inout ByteReader, version: Int) throws -> (Int?, Shell?) {
        _ = try r.u8()                                   // byte "general"
        let sub = try r.u8()
        let sub2 = sub & 0x80 != 0 ? try r.u16() : 0
        let idx: Int? = sub & 0x10 != 0 ? nil : Int(try r.u32())
        if sub & 0x20 != 0 { try r.skip(1 + 24); return (idx, nil) }       // só caixa envolvente
        if sub2 & 0x02 != 0 { try r.skip(1); return (idx, nil) }           // shell nulo
        if sub2 & 0x01 != 0 { throw HSFError(message: "shell coleção") }
        let lod = try r.u8()
        let scheme = sub & 0x41 != 0 ? try r.u8() : 4
        var points: [SIMD3<Float>]
        var tris: [UInt32]
        if scheme == 5 {
            let L = try r.i32()
            let blob = Array(try r.bytes(L))
            let eb = try Edgebreaker.decode(blob)
            points = eb.points
            tris = eb.triangles
            if sub & 0x01 == 0 {
                let f = try r.floats(3 * eb.pointCount)
                points = stride(from: 0, to: f.count, by: 3).map { SIMD3(f[$0], f[$0 + 1], f[$0 + 2]) }
            }
        } else {
            if scheme == 1 {
                let n = try r.i32()
                let bb = try r.floats(6)
                let bits = try r.u8()
                let L = try r.i32()
                points = trivialPoints(n, bb, bits, Array(try r.bytes(L)))
            } else if scheme == 4 {
                let n = try r.i32()
                let f = try r.floats(3 * n)
                points = stride(from: 0, to: f.count, by: 3).map { SIMD3(f[$0], f[$0 + 1], f[$0 + 2]) }
            } else {
                throw HSFError(message: "esquema de pontos \(scheme)")
            }
            _ = try r.u8()
            let L = try r.i32()
            let ints = trivialInts(Array(try r.bytes(L)), signed: sub2 & 0x04 != 0)
            tris = facesToTriangles(ints, strips: sub & 0x04 != 0, pointCount: points.count)
        }
        if sub & 0x08 != 0 {
            try readOptionals(&r, points: points.count, faces: tris.count / 3)
        }
        if version >= 2300 { try r.skip(4) }
        return (idx, Shell(points: points, triangles: tris, lod: lod))
    }

    static func trivialPoints(_ n: Int, _ bb: [Float], _ bits: Int, _ data: [UInt8]) -> [SIMD3<Float>] {
        if bits == 8 {   // caso especial do HOOPS: bytes em sequência (não palavras de 32 bits)
            return (0..<n).map { i in
                var p = SIMD3<Float>()
                for k in 0..<3 {
                    let v = 3 * i + k < data.count ? data[3 * i + k] : 0
                    p[k] = v == 255 ? bb[k + 3] : bb[k] + Float(v) * (bb[k + 3] - bb[k]) / 255
                }
                return p
            }
        }
        var br = BitReader(data)
        let mx = UInt32((1 << bits) - 1)
        let span = SIMD3(bb[3] - bb[0], bb[4] - bb[1], bb[5] - bb[2])
        let lo = SIMD3(bb[0], bb[1], bb[2]), hi = SIMD3(bb[3], bb[4], bb[5])
        var out = [SIMD3<Float>]()
        out.reserveCapacity(n)
        for _ in 0..<n {
            var p = SIMD3<Float>()
            for k in 0..<3 {
                let v = br.read(bits)
                p[k] = v == mx ? hi[k] : lo[k] + Float(v) * span[k] / Float(mx)
            }
            out.append(p)
        }
        return out
    }

    static func trivialInts(_ d: [UInt8], signed: Bool) -> [Int] {
        guard let first = d.first else { return [] }
        let w = Int(first >> 3)
        guard w == 1 || w == 2 || w == 4 else { return [] }
        let n = (d.count - 1) / w
        var out = [Int](repeating: 0, count: n)
        for k in 0..<n {
            let o = 1 + k * w
            switch w {
            case 1: out[k] = signed ? Int(Int8(bitPattern: d[o])) : Int(d[o])
            case 2:
                let u = UInt16(d[o]) | UInt16(d[o + 1]) << 8
                out[k] = signed ? Int(Int16(bitPattern: u)) : Int(u)
            default:
                out[k] = Int(Int32(bitPattern: UInt32(d[o]) | UInt32(d[o + 1]) << 8 | UInt32(d[o + 2]) << 16 | UInt32(d[o + 3]) << 24))
            }
        }
        return out
    }

    /// Converte lista de faces (contagem, índices…) ou faixas de triângulos em triângulos.
    static func facesToTriangles(_ f: [Int], strips: Bool, pointCount: Int) -> [UInt32] {
        var tris = [UInt32]()
        tris.reserveCapacity(f.count * 2)
        var i = 0
        func ok(_ v: Int) -> Bool { v >= 0 && v < pointCount }
        while i < f.count {
            let n = f[i]; i += 1
            let m = abs(n)
            guard m > 0, i + m <= f.count else { break }
            let v = Array(f[i..<(i + m)])
            i += m
            if m < 3 || !v.allSatisfy(ok) { continue }
            if strips {
                if n > 0 {
                    for k in 2..<m {
                        let t = k % 2 == 0 ? (v[k - 2], v[k - 1], v[k]) : (v[k - 1], v[k - 2], v[k])
                        tris += [UInt32(t.0), UInt32(t.1), UInt32(t.2)]
                    }
                } else {
                    for k in 2..<m { tris += [UInt32(v[0]), UInt32(v[k - 1]), UInt32(v[k])] }
                }
            } else if n > 0 {
                for k in 2..<m { tris += [UInt32(v[0]), UInt32(v[k - 1]), UInt32(v[k])] }
            }
        }
        return tris
    }

    static func readOptionals(_ r: inout ByteReader, points: Int, faces: Int) throws {
        while true {
            let op = try r.u8()
            switch op {
            case 0: return
            case 1, 5, 7, 9, 0x1d:            // normais/cores comprimidas para todos os vértices
                try r.skip(2); try r.skip(try r.i32())
            case 0x11: try r.skip(12 * points)
            case 0x13: try r.skip(8 * points)
            case 0x33:                          // regiões de face
                let comp = try r.u8()
                var count = 0
                if comp & 3 != 0 {
                    switch comp & 0x18 {
                    case 0: count = try r.i32()
                    case 8: count = try r.u8()
                    default: count = try r.u16()
                    }
                }
                let n = [faces, count, count + 1, count * 2][comp & 3]
                try r.skip(n * [0: 4, 8: 1, 0x10: 2][comp & 0x18, default: 4])
            default:
                throw HSFError(message: String(format: "atributo opcional 0x%02x", op))
            }
        }
    }
}

// MARK: - Bits (MSB primeiro, palavras de 32 bits little-endian)

struct BitReader {
    var words: [UInt32]
    var w = 0
    var pos = 0

    init(_ data: [UInt8]) {
        let n = (data.count + 3) / 4
        words = [UInt32](repeating: 0, count: n + 1)
        for i in 0..<data.count { words[i / 4] |= UInt32(data[i]) << (8 * UInt32(i % 4)) }
    }

    mutating func read(_ n: Int) -> UInt32 {
        let mask: UInt32 = n >= 32 ? 0xffff_ffff : (1 << UInt32(n)) - 1
        let word = words[w]
        if pos + n <= 32 {
            let v = (word >> UInt32(32 - pos - n)) & mask
            pos += n
            return v
        }
        let over = pos + n - 32
        var v = (word << UInt32(over)) & mask
        w += 1
        v |= words[w] >> UInt32(32 - over)
        pos = over
        return v
    }

    /// Códigos em cascata: lê n bits; se vierem todos em 1, tenta a próxima largura.
    mutating func cascade(_ widths: [Int]) -> Int {
        for (k, n) in widths.enumerated() {
            let v = read(n)
            let allOnes: UInt32 = (1 << UInt32(n)) - 1
            if v != allOnes || k == widths.count - 1 {
                return Int(v) - ((1 << (n - 1)) - 1)
            }
        }
        return 0
    }
}
