#!/usr/bin/env python3
"""Leitor HSF completo (protótipo): segmentos, matrizes, cores, tags e shells → malhas no espaço do modelo."""
import struct, sys, zlib
sys.path.insert(0, __file__.rsplit('/', 1)[0])
import hsf_decode


class Unsupported(Exception):
    pass


class Reader:
    def __init__(self, b):
        self.b = b; self.i = 0
    def u8(self): v = self.b[self.i]; self.i += 1; return v
    def u16(self): v = struct.unpack_from('<H', self.b, self.i)[0]; self.i += 2; return v
    def i32(self): v = struct.unpack_from('<i', self.b, self.i)[0]; self.i += 4; return v
    def u32(self): v = struct.unpack_from('<I', self.b, self.i)[0]; self.i += 4; return v
    def f(self, n): v = struct.unpack_from('<%df' % n, self.b, self.i); self.i += 4 * n; return v
    def raw(self, n):
        if n < 0 or self.i + n > len(self.b): raise Unsupported('fim inesperado')
        v = self.b[self.i:self.i + n]; self.i += n; return v
    def var(self):
        v = self.u8(); full = v; shift = 8
        while v & 0x80:
            v = self.u8(); full |= v << shift; shift += 8
        return full


def load_body(path):
    d = open(path, 'rb').read()
    if not d.startswith(b';; HSF V'): raise Unsupported('não é HSF')
    version = int(round(float(d[8:d.index(b' ', 8)].decode()) * 100))
    i = d.index(b'\n') + 1
    head = {'version': version}
    while i < len(d):
        op = d[i]; i += 1
        if op == ord('I'): head['flags'] = struct.unpack_from('<I', d, i)[0]; i += 4
        elif op == 0x14:
            fmt, w, h = d[i], d[i + 1] or 256, d[i + 2] or 256; i += 3
            i += w * h * (3 if fmt == 0 else 4 if fmt == 1 else 1)
        elif op == ord('B'):
            opts = d[i]; i += 1; t = d[i]; i += 1
            dbl = opts & 1
            if t == 0:
                head['bbox'] = struct.unpack_from('<6d' if dbl else '<6f', d, i); i += 48 if dbl else 24
            else: i += 32 if dbl else 16
        elif op == ord(';'):
            i = d.index(b'\n', i) + 1
        elif op == ord('Z'):
            # o arquivo pode ter vários blocos zlib separados por opcodes crus (pausas, dicionário)
            body = bytearray()
            pos = i
            while True:
                z = zlib.decompressobj()
                try:
                    out = z.decompress(d[pos:])
                except zlib.error:
                    break
                body += out
                pos = len(d) - len(z.unused_data)
                nxt = -1
                k = d.find(b'Z', pos)
                while k >= 0 and k + 2 < len(d):
                    if d[k + 1] == 0x78 and ((d[k + 1] << 8) | d[k + 2]) % 31 == 0:
                        nxt = k; break
                    k = d.find(b'Z', k + 1)
                if nxt < 0: break
                pos = nxt + 1
            return head, bytes(body)
        else:
            # fluxo sem compressão
            return head, d[i - 1:]
    return head, b''


def mat_mul(a, b):  # 4x4 linha-vetor (HOOPS): p' = p · M
    return [[sum(a[r][k] * b[k][c] for k in range(4)) for c in range(4)] for r in range(4)]

IDENT = [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]]


def read_shell(r, gen_byte=True):
    if gen_byte: r.u8()
    sub = r.u8(); sub2 = r.u16() if sub & 0x80 else 0
    idx = None if sub & 0x10 else r.u32()
    if sub & 0x20:  # só caixa envolvente
        r.u8(); r.f(6); return idx, None
    if sub2 & 0x02:  # shell nulo (placeholder do primeiro passo)
        r.u8(); return idx, None
    if sub2 & 0x01:
        raise Unsupported('shell coleção')
    lod = r.u8()
    scheme = r.u8() if sub & 0x41 else 4
    pts = faces = None; strips = bool(sub & 0x04)
    if scheme == 5:  # edgebreaker
        L = r.i32(); blob = r.raw(L)
        pts, tris, info = hsf_decode.decode_edgebreaker(blob)
        faces = ('tris', tris)
        if not sub & 0x01:
            pts = [tuple(r.f(3)) for _ in range(info['npts'])]
    else:
        if scheme == 1:  # pontos quantizados
            n = r.i32(); bbox = r.f(6); bits = r.u8(); L = r.i32(); data = r.raw(L)
            pts = trivial_points(n, bbox, bits, data)
        elif scheme == 4:
            n = r.i32(); pts = [tuple(r.f(3)) for _ in range(n)]
        else:
            raise Unsupported('esquema de pontos %d' % scheme)
        fs = r.u8(); L = r.i32(); data = r.raw(L)
        ints = trivial_ints(data, bool(sub2 & 0x04))
        faces = ('strips' if strips else 'flist', ints)
    if sub & 0x08:
        nfaces = len(faces[1]) if faces[0] == 'tris' else count_faces(faces[0], faces[1])
        read_optionals(r, len(pts), nfaces)
    return idx, (pts, faces, lod)


def count_faces(kind, data):
    i = n = 0
    while i < len(data):
        k = data[i]
        if kind == 'strips': n += abs(k) - 2
        elif k > 0: n += 1
        i += abs(k) + 1
    return n


def trivial_points(n, bbox, bits, data):
    if bits == 8:   # caso especial do HOOPS: bytes em sequência
        return [tuple(bbox[k + 3] if data[3 * i + k] == 255 else bbox[k] + data[3 * i + k] * (bbox[k + 3] - bbox[k]) / 255 for k in range(3)) for i in range(n)]
    b = hsf_decode.Bits(data + b'\0\0\0\0')
    mx = (1 << bits) - 1
    out = []
    for _ in range(n):
        p = []
        for k in range(3):
            v = b.read(bits)
            p.append(bbox[k + 3] if v == mx else bbox[k] + v * (bbox[k + 3] - bbox[k]) / mx)
        out.append(tuple(p))
    return out


def trivial_ints(data, signed):
    w = data[0] >> 3
    body = data[1:]
    n = len(body) // w
    fmt = {1: 'b' if signed else 'B', 2: 'h' if signed else 'H', 4: 'i'}[w]
    return list(struct.unpack_from('<%d%s' % (n, fmt), body, 0))


def read_optionals(r, npts, nfaces):
    while True:
        op = r.u8()
        if op == 0: return
        if op in (1, 5, 7, 9, 0x1d):  # normais/cores comprimidas para todos os vértices
            r.u8(); r.u8(); L = r.i32(); r.raw(L)
        elif op == 0x11: r.f(3 * npts)
        elif op == 0x13: r.f(2 * npts)
        elif op == 0x33:
            comp = r.u8(); count = 0
            if comp & 3:
                size = comp & 0x18
                count = r.i32() if size == 0 else r.u8() if size == 8 else r.u16()
            n = {0: nfaces, 1: count, 2: count + 1, 3: count * 2}[comp & 3]
            r.raw(n * {0: 4, 8: 1, 0x10: 2}[comp & 0x18])
        else:
            raise Unsupported('opcional 0x%02x' % op)


def read_heuristics(r, v):
    mask = r.u16()
    if mask & 0x8000: mask |= r.u16() << 16
    if mask & 0x80000000: r.i32()
    value = r.u16()
    if mask & 0x8000: value |= r.u16() << 16
    if mask & 0x80000000: r.i32()
    mv = mask & value
    if mv & 0x40: r.i32()
    if mv & 0x80: r.i32()
    if mv & 0x0c: r.u8()
    c = 0
    if v >= 0x2c2 and mask & 0x10000 and mv & 0x10000: c = r.u8()
    if c & 0x80: c |= r.u8() << 8
    if c & 0x8000: c |= r.u16() << 16
    big = mask & 0x10000
    if v >= 0x4b1 and big:
        if c & 2: r.i32()
        if c & 4: r.i32()
        if c & 0x200: r.i32()
    if mask & 0x200000:
        b = r.u8()
        for i in range(6):
            if b & (1 << i): r.i32()
    if mv & 0x400000: r.i32()
    if mask & 0x1000000: r.u8()
    if big and c & 0x400: r.raw(12)
    if big and c & 0x800: r.f(1)
    if big and c & 0x4000: r.i32()
    if big and c & 0x10000: r.u8()
    if mv & 0x4000000: r.i32()
    if mv & 0x8000000: r.u8()
    if big and c & 0x100000: r.f(1)
    if big and c & 0x400000: r.raw(24)
    if mv & 0x10000000: r.i32()
    if mv & 0x20000000: r.u16()
    if mv & 0x4000 and v >= 0x808: r.u8()
    if mask & 0x40000000: r.u16()


def faces_to_tris(kind, data):
    tris = []
    if kind == 'tris': return list(data)
    i = 0
    while i < len(data):
        n = data[i]; i += 1
        if kind == 'strips':
            m = abs(n); v = data[i:i + m]; i += m
            if n > 0:
                for k in range(2, m):
                    t = (v[k - 2], v[k - 1], v[k]) if k % 2 == 0 else (v[k - 1], v[k - 2], v[k])
                    tris.append(t)
            else:
                for k in range(2, m): tris.append((v[0], v[k - 1], v[k]))
        else:
            m = abs(n); v = data[i:i + m]; i += m
            if n > 0:
                for k in range(2, m): tris.append((v[0], v[k - 1], v[k]))
    return tris


VALID = set(b'()%}m"~U-qS<{VHJ?zs:r&!hlLg\x00\x01\x18')


def lookahead_ok(body, j, version, n=25):
    if j >= len(body): return True
    probe = Reader(body); probe.i = j
    good = 0; strong = False
    try:
        for _ in range(n):
            if probe.i >= len(body): return True
            op = body[probe.i]
            if op not in VALID: return good >= 4 and strong
            if op in (0x28, 0x29, 0x53): strong = True
            if op == ord('('):
                L = body[probe.i + 1]; name = body[probe.i + 2:probe.i + 2 + L]
                if not all(32 <= c < 127 for c in name): return False
            if op in (ord('z'),): return True
            if not step(probe, version): return False
            good += 1
        return True
    except Exception:
        return False


def resync(body, start, version):
    for j in range(start + 4, min(len(body), start + 2000)):
        if body[j] in VALID and lookahead_ok(body, j, version):
            return j
    raise Unsupported('não consegui pular R')


def new_seg(name, parent):
    return {'name': name, 'matrix': IDENT, 'color': None, 'items': [], 'parent': parent}


def child(seg, name):
    for it in seg['items']:
        if 'items' in it and it['name'] == name and name: return it
    return None


def open_path(c, cur, name):
    """Abre (criando se preciso) um segmento por nome simples ou caminho relativo/absoluto."""
    if '/' not in name and not name.startswith('..') and not name.startswith('?'):
        if name:
            ex = child(cur, name)
            if ex: return ex
        seg = new_seg(name, cur); cur['items'].append(seg); return seg
    return resolve(c, cur, name, create=True)


def resolve(c, cur, path, create=False):
    if path.startswith('?') or path.startswith('/'):
        node = c.root
        parts = [p for p in (path[1:] if path.startswith('/') else path).split('/') if p]
        if path.startswith('?'): parts = [path.split('/')[0]] + [p for p in path.split('/')[1:] if p]
    else:
        node = cur; parts = [p for p in path.split('/') if p]
    for p in parts:
        if p == '..': node = node.get('parent') or node; continue
        if p == '.': continue
        nxt = child(node, p)
        if nxt is None:
            if not create: return None
            nxt = new_seg(p, node); node['items'].append(nxt)
        node = nxt
    return node


class Ctx:
    def __init__(self, version):
        self.version = version
        self.root = {'name': '', 'matrix': IDENT, 'color': None, 'items': [], 'parent': None}
        self.stack = [self.root]
        self.tags = []
        self.last_obj = None
        self.refinements = []
        self.instances = []
        self.geo_attr = False
        self.last_ref = None
        self.done = False


def step(r, version, c=None):
    """Lê um opcode. Sem contexto (c=None) só valida/avança (usado no lookahead)."""
    if c is None: c = Ctx(version); c.probe = True
    op = r.u8()
    if op not in (ord('%'), ord(':')): c.geo_attr = c.geo_attr and op in (ord('"'), ord('~'), ord('V'))
    if op not in (ord('r'), ord('%'), ord(':'), ord('"'), ord('~'), ord('V')): c.last_ref = None
    st = c.stack
    if op == ord('('):
        name = r.raw(r.u8()).decode('latin1')
        seg = open_path(c, st[-1], name)
        st.append(seg); c.last_obj = seg
    elif op == ord(')'):
        if len(st) > 1: c.last_obj = st.pop()
    elif op in (0x00, 0x01): pass
    elif op == ord('%'):
        r.u8(); m = r.f(12)
        M = [[m[0], m[1], m[2], 0], [m[3], m[4], m[5], 0], [m[6], m[7], m[8], 0], [m[9], m[10], m[11], 1]]
        if c.geo_attr and c.last_ref is not None: c.last_ref['matrix'] = M
        else: st[-1]['matrix'] = M
    elif op == ord('}'):
        proj = r.u8(); r.u8(); r.f(11)
        for bit in (0x10, 0x20, 0x40):
            if proj & bit: r.f(1)
        r.raw(r.u8())
    elif op == ord('m'):
        n = r.u32()
        if n > 10000: raise Unsupported('m')
        for _ in range(n):
            r.raw(4); r.raw(r.u32())
    elif op == ord('"'):
        geo = r.var(); ch = r.var(); diffuse = None
        for bit in range(16):
            if not ch & (1 << bit): continue
            if bit in (5, 6): r.f(1); continue
            L = r.u8()
            val = r.raw(3) if L == 0 else r.raw(L)
            if bit == 0 and L == 0: diffuse = tuple(val)
        if diffuse: st[-1]['color'] = diffuse
    elif op == ord('~'):
        r.var(); st[-1]['color'] = tuple(r.raw(3))
    elif op == ord('U'):
        L = r.u16()
        if L == 0xffff: L = r.u32()
        r.raw(L)
    elif op == ord('-'):
        L = r.u8()
        if L == 0xff: L = r.u8()
        r.raw(L)
    elif op == ord('q'):
        c.tags.append(c.last_obj)
    elif op == ord('S'):
        idx, mesh = read_shell(r)
        if idx is None:
            obj = {'shell': mesh}
            st[-1]['items'].append(obj); c.last_obj = obj
        else:
            c.refinements.append((idx, mesh))
    elif op in (ord('<'), ord('{')):
        g = r.u8()
        if g & 0xfc: raise Unsupported('ref flags')
        L = r.u8()
        if L == 0xff: L = r.u32()
        name = r.raw(L).decode('latin1')
        if g & 1:
            C = r.u8()
            if C == 0xff: C = r.u32()
            r.raw(C)
        if g & 2: raise Unsupported('lock masks')
        if op == ord('<'): st[-1]['items'].append({'include': name, 'from': st[-1]})
        else: st[-1]['style'] = (name, st[-1])
    elif op == ord('z'):
        pass
    elif op == ord('s'):
        idx = r.i32()
        if getattr(c, 'probe', False): st.append({'items': [], 'matrix': IDENT, 'color': None, 'name': ''})
        else:
            seg = c.tags[idx] if 0 <= idx < len(c.tags) else None
            if not seg or 'items' not in seg: raise Unsupported('reabrir segmento %d' % idx)
            st.append(seg)
    elif op == ord(':'):
        c.geo_attr = True
    elif op == ord('r'):
        idx = r.i32(); L = r.u8()
        if L == 0xff: L = r.u32()
        r.raw(L)
        ref = {'ref': idx, 'matrix': None}
        st[-1]['items'].append(ref); c.last_ref = ref
    elif op == ord('&'):
        frm = r.i32(); r.i32(); to = r.i32(); r.i32(); r.u8(); m = r.f(12)
        c.instances.append((frm, to, m))
    elif op == ord('!'):
        g = r.u8(); w = 2 if g & 0x80 else 1
        r.raw(w - 1 + 5 * w)
    elif op == ord('h'):
        r.u8()
    elif op == ord('R'):
        if getattr(c, 'probe', False): return False
        r.i = resync(r.b, r.i, version)
    elif op == 0x18:
        L = r.i32(); r.raw(L)
    elif op == ord('l'):
        g = r.u8(); r.raw(48 if g & 1 else 24)
    elif op in (ord('L'), ord('g')):
        g = r.u8(); n = abs(r.i32())
        if n > 10000000: raise Unsupported('polyline')
        r.raw(n * 3 * (8 if g & 1 else 4))
    elif op == ord('V'):
        m = r.u8(); v = r.u8()
        if m & 0x80: m |= r.u16() << 8; v |= r.u16() << 8
        if m & 0x800000: m |= r.u8() << 24; v |= r.u8() << 24
        if m & 0x01: st[-1]['faces'] = bool(v & 0x01)
    elif op == ord('H'):
        read_heuristics(r, version)
    elif op == ord('J'):
        L = r.u8()
        if L == 0xff: L = r.u32()
        r.raw(L); r.raw(r.u16())
    elif op == ord('?'):
        L = r.u8()
        if L == 0xff: L = r.u32()
        elif L == 0xfe: L = r.u16()
        r.raw(L)
    else:
        raise Unsupported('opcode %r em %d: %s' % (chr(op) if 32 <= op < 127 else hex(op), r.i - 1, r.b[r.i - 1:r.i + 23]))
    return True


def parse(path, survey=None):
    head, body = load_body(path)
    r = Reader(body)
    c = Ctx(head['version'])
    head['warning'] = None
    while r.i < len(body) and not c.done:
        if survey is not None:
            op = body[r.i]; survey[op] = survey.get(op, 0) + 1
        try:
            step(r, head['version'], c)
        except Unsupported as e:
            # mantém o que já foi lido (ex.: linhas PolyPolypoint no fim do arquivo)
            head['warning'] = str(e)
            break
    tags = c.tags
    for idx, mesh in c.refinements:
        if idx < len(tags) and tags[idx] is not None and mesh is not None:
            tags[idx]['shell'] = mesh
    for frm, to, m in c.instances:
        src = tags[frm].get('shell') if frm < len(tags) and tags[frm] else None
        if src and to < len(tags) and tags[to] is not None:
            pts, faces, lod = src
            moved = [tuple(p[0] * m[k] + p[1] * m[3 + k] + p[2] * m[6 + k] + m[9 + k] for k in range(3)) for p in pts]
            tags[to]['shell'] = (moved, faces, lod)
    c.root['tags'] = tags
    return head, c.root


def flatten(root):
    """Percorre segmentos acumulando matrizes; retorna lista de (vértices, triângulos, cor)."""
    out = []
    tags = root.get('tags', [])
    class _R: pass
    ctx_root = _R(); ctx_root.root = root
    def emit(shell, M, c):
        pts, (kind, data), lod = shell
        if lod != 0: return
        tris = faces_to_tris(kind, data)
        vs = [tuple(p[0] * M[0][k] + p[1] * M[1][k] + p[2] * M[2][k] + M[3][k] for k in range(3)) for p in pts]
        out.append((vs, tris, c))
    def walk(seg, M, color, visible, depth=0, included=False):
        if depth > 40: return
        M2 = mat_mul(seg['matrix'], M)
        c = seg['color'] or color
        vis = seg.get('faces', visible)
        if seg.get('name', '').startswith('?') and not included: return   # biblioteca: só por referência
        if not seg['color'] and seg.get('style'):
            stl = resolve(ctx_root, seg['style'][1], seg['style'][0])
            if stl and stl.get('color'): c = stl['color']
        for it in seg['items']:
            if 'items' in it: walk(it, M2, c, vis, depth + 1)
            elif 'include' in it and vis:
                t = resolve(ctx_root, it['from'], it['include'])
                if t is not None and t is not seg: walk(t, M2, c, True, depth + 1, included=True)
            elif it.get('shell') and vis: emit(it['shell'], M2, c)
            elif 'ref' in it and vis:
                t = tags[it['ref']] if 0 <= it['ref'] < len(tags) else None
                M3 = mat_mul(it['matrix'], M2) if it['matrix'] else M2
                if t is None: continue
                if t.get('shell'): emit(t['shell'], M3, c)
                elif 'items' in t: walk(dict(t, faces=True), M3, c, True, depth + 1)
    walk(root, IDENT, None, True)
    return out


if __name__ == '__main__':
    import glob, collections, traceback
    files = sys.argv[1:]
    survey = {}; errors = collections.Counter(); ok = 0
    for f in files:
        try:
            head, root = parse(f, survey)
            if head['warning']: raise Unsupported(head['warning'])
            ok += 1
        except Exception as e:
            msg = str(e)
            key = msg.split(' em ')[0] if 'opcode' in msg else msg[:60]
            errors[key] += 1
    print('ok', ok, 'de', len(files))
    for k, v in errors.most_common(30): print(v, k)
    print({(chr(k) if 32 <= k < 127 else hex(k)): v for k, v in sorted(survey.items(), key=lambda x: -x[1])})
