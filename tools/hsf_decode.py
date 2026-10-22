#!/usr/bin/env python3
"""Decodificador de shells HSF com compressão edgebreaker (esquema 2, pontos esquema 2/3).

Reimplementação própria a partir da análise do formato HOOPS Stream usado pelo DXQ3D.onsite.
Uso exploratório; a versão de produção é Sources/CellCore/HSF.swift.
"""
import struct

NONE = -0x7f7f7f80          # 0x80808080: sem referência
DUMMY = -0x7ffffffd         # 0x80000003: vértice fictício (removido)
CASC_RESID = [2, 6, 10, 14, 18, 22, 26, 31]
CASC_COUNT = [16, 31]


class Bits:
    """Leitor de bits MSB-first dentro de palavras de 32 bits little-endian."""
    def __init__(self, data):
        n = len(data) // 4
        self.w = struct.unpack_from('<%dI' % n, data, 0) + (0,)
        self.i = 0
        self.pos = 0

    def read(self, n):
        word = self.w[self.i]
        if self.pos + n <= 32:
            v = (word >> (32 - self.pos - n)) & ((1 << n) - 1)
            self.pos += n
            return v
        over = self.pos + n - 32
        v = (word << over) & ((1 << n) - 1)
        self.i += 1
        v |= self.w[self.i] >> (32 - over)
        self.pos = over
        return v

    def cascade(self, widths):
        for k, n in enumerate(widths):
            v = self.read(n)
            if v != (1 << n) - 1 or k == len(widths) - 1:
                return v - ((1 << (n - 1)) - 1)
        raise ValueError


def nxt(c): return (c // 3) * 3 + (c + 1) % 3
def prv(c): return (c // 3) * 3 + (c + 2) % 3


def parse_mtable(buf, off):
    u = lambda: struct.unpack_from('<I', buf, off[0])[0]
    def rd():
        v = struct.unpack_from('<i', buf, off[0])[0]; off[0] += 4; return v
    m = {'flags': rd()}
    f = m['flags']
    nlen = rd() if f & 1 else 0
    nm2 = rd() if f & 2 else 0
    ndum = rd() if f & 8 else 0
    npat = rd() if f & 0x10 else 0
    m['mlengths'] = [rd() for _ in range(nlen)]
    m['m2stack'] = [rd() for _ in range(nm2)]
    m['m2gate'] = [rd() for _ in range(nm2)]
    d, prev = [], 0
    for _ in range(ndum):
        prev = prev + rd(); d.append(prev)
    m['dummies'] = d
    patches, prev = {}, 0
    for _ in range(npat // 2):
        old = rd() + prev; new = rd(); patches[old] = new; prev = old
    m['patches'] = patches
    m['bbox'] = None
    if f & 0x20:
        m['bbox'] = struct.unpack_from('<6f', buf, off[0]); off[0] += 24
    m['quant'] = [rd(), rd(), rd()] if f & 0x40 else [11, 11, 11]
    m['nquant'] = [rd(), rd(), rd()] if f & 0x80 else [11, 11, 11]
    return m


def prescan(ops, start, mt):
    """Varre um componente para obter o comprimento inicial da fronteira e os deslocamentos dos S."""
    length = 0; s_stack = []; l_stack = []; s_count = 0; offsets = {}; mi = 0
    for i in range(start, len(ops)):
        op = ops[i]
        if op == 0: length -= 1
        elif op in (1, 3): length += 1
        elif op == 2:
            length += 3
            if not l_stack: break
            s = s_stack.pop(); t = l_stack.pop()
            offsets[s] = length - t - 2
        elif op == 4:
            s_stack.append(s_count); l_stack.append(length - 1); s_count += 1; length -= 1
        elif op == 5:
            length += -1 - mt['mlengths'][mi]; mi += 1
        else:
            raise ValueError('M2 não suportado')
    return length, offsets


def decode_connectivity(ops, mt):
    corners_v, corners_o = [], []
    faces = []
    nv = 0
    pos = 0
    while pos < len(ops):
        loop, offsets = prescan(ops, pos, mt)
        if loop < 1: raise ValueError('laço inicial inválido')
        nextn = {}; prevn = {}; vid = {}; ref = {}
        for k in range(loop):
            prevn[k] = k - 1; nextn[k] = k + 1; vid[k] = nv; nv += 1; ref[k] = NONE
        prevn[0] = loop - 1; nextn[loop - 1] = 0
        free = []; free_next = loop
        s_stack = []; s_i = 0
        g = 0
        done = False
        while not done:
            c = len(corners_v)
            corners_v += [0, 0, 0]; corners_o += [NONE, NONE, NONE]
            a, b = vid[g], vid[nextn[g]]
            if not free:
                free.append(free_next); free_next += 1
            r = ref[g]
            if r != NONE: corners_o[r] = c
            corners_o[c] = r
            corners_v[c] = a; corners_v[c + 1] = b
            op = ops[pos]; pos += 1
            if op == 0:    # C
                third = nv
                n = free.pop()
                p = prevn[g]
                nextn[p] = n; prevn[n] = p; nextn[n] = g; prevn[g] = n
                vid[n] = vid[g]; vid[g] = nv
                ref[g] = c + 1; ref[n] = c + 2
                nv += 1
            elif op == 1:  # L
                p = prevn[g]
                third = vid[p]
                r2 = ref[p]
                corners_o[c + 2] = r2
                if r2 != NONE: corners_o[r2] = c + 2
                vid[g] = vid[p]
                free.append(p)
                pp = prevn[p]; prevn[g] = pp; nextn[pp] = g
                ref[g] = c + 1
            elif op == 2:  # E
                p = prevn[g]; n_ = nextn[g]
                third = vid[p]
                r1 = ref[n_]; corners_o[c + 1] = r1
                if r1 != NONE: corners_o[r1] = c + 1
                r2 = ref[p]; corners_o[c + 2] = r2
                if r2 != NONE: corners_o[r2] = c + 2
                free += [g, p, n_]
                if not s_stack: done = True
                else: g = s_stack.pop()
            elif op == 3:  # R
                n_ = nextn[g]; nn = nextn[n_]
                third = vid[nn]
                r1 = ref[n_]; corners_o[c + 1] = r1
                if r1 != NONE: corners_o[r1] = c + 1
                free.append(n_)
                nextn[g] = nn; prevn[nn] = g
                ref[g] = c + 2
            elif op == 4:  # S
                off = offsets[s_i]; s_i += 1
                s = g
                for _ in range(off + 1): s = nextn[s]
                ns = nextn[s]
                third = vid[ns]
                n = free.pop(); s_stack.append(n)
                p = prevn[g]
                nextn[p] = n; prevn[n] = p; nextn[n] = ns; prevn[ns] = n
                ref[n] = c + 2; vid[n] = vid[g]; vid[g] = vid[ns]; ref[g] = c + 1
                prevn[g] = s; nextn[s] = g
            else:
                raise ValueError('op %d' % op)
            corners_v[c + 2] = third
            if a == b or b == third or third == a: raise ValueError('triângulo degenerado no op %d' % pos)
            faces.append((a, b, third))
    return corners_v, corners_o, faces, nv


def compact(nv, mt, corners_v, faces):
    dst = [0] * nv
    for d in mt['dummies']: dst[d] = 'D'
    for old in mt['patches']: dst[old] = 'P'
    k = 0
    for v in range(nv):
        if dst[v] in ('D', 'P'): k += 1
        else: dst[v] = k
    def remap(v):
        t = dst[v]
        if t == 'D': return DUMMY
        if t == 'P': return mt['patches'][v]
        return v - t
    faces2 = [tuple(remap(v) for v in f) for f in faces if not any(dst[v] == 'D' for v in f)]
    cv = [remap(v) for v in corners_v]
    return cv, faces2


def decode_points(cv, co, npts, header, data, mt):
    bits = Bits(data)
    has_strips = bits.cascade(CASC_RESID) != 0
    n_abs = bits.cascade(CASC_COUNT)
    n_res = bits.cascade(CASC_COUNT)
    absp = [[bits.cascade(CASC_COUNT) for _ in range(3)] for _ in range(n_abs)]
    resid = [[bits.cascade(CASC_RESID) for _ in range(3)] for _ in range(n_res)]
    pts = [None] * npts
    seen = [False] * npts
    ai = ri = 0
    ncorn = len(cv)
    for c in range(ncorn):
        v = cv[c]
        if v < 0 or seen[v]: continue
        v1, v2 = cv[nxt(c)], cv[prv(c)]
        if v1 < 0 or v2 < 0: continue
        stack = []
        k = c
        for _ in range(3):
            vk = cv[k]
            if vk >= 0 and not seen[vk]:
                seen[vk] = True; pts[vk] = absp[ai]; ai += 1
            if co[k] >= 0: stack.append(k)
            k = nxt(k)
        while stack:
            k = stack.pop()
            c2 = co[k]
            u = cv[prv(c2)]
            if u == DUMMY or u < 0 or seen[u]: continue
            va, vb = cv[c2], cv[nxt(c2)]
            vc = cv[prv(co[c2] & 0x7fffffff)]
            pa, pb, pc = pts[va], pts[vb], pts[vc]
            pred = [pb[i] - pc[i] + pa[i] for i in range(3)]
            res = resid[ri]; ri += 1
            pts[u] = [pred[i] - res[i] for i in range(3)]
            n1 = nxt(c2)
            if co[n1] >= 0: stack.append(n1)
            n2 = nxt(n1)
            if co[n2] >= 0: stack.append(n2)
            seen[u] = True
    return pts, (ai, n_abs, ri, n_res), has_strips


def dequantize(pts, bbox, q):
    out = []
    mx = [(1 << b) - 1 for b in q]
    step = [(bbox[i + 3] - bbox[i]) / mx[i] if bbox[i + 3] != bbox[i] else 0 for i in range(3)]
    for p in pts:
        if p is None: out.append((0, 0, 0)); continue
        out.append(tuple(bbox[i + 3] if p[i] == mx[i] else bbox[i] + p[i] * step[i] for i in range(3)))
    return out


def decode_edgebreaker(blob):
    scheme, mts, ps, ns = blob[0], blob[1], blob[2], blob[3]
    opslen, mtlen, plen, npts = struct.unpack_from('<4i', blob, 4)
    hdr = 0x14 if scheme == 0 else 0x18
    ops = blob[hdr:hdr + opslen]
    o = hdr + opslen
    o += (-o) % 4
    mt = parse_mtable(blob, [o])
    o += mtlen
    o += (-o) % 4
    pdata = blob[o:o + plen]
    if scheme < 2:
        raise NotImplementedError('esquema edgebreaker %d' % scheme)
    cv, co, faces, nv = decode_connectivity(ops, mt)
    cv, faces = compact(nv, mt, cv, faces)
    ipts, stats, strips = decode_points(cv, co, npts, blob[:4], pdata, mt)
    pts = dequantize(ipts, mt['bbox'], mt['quant'])
    return pts, faces, {'ops': opslen, 'nv': nv, 'npts': npts, 'stats': stats, 'strips': strips, 'mt': mt['flags']}
