#!/usr/bin/env python3
"""Percorre os opcodes HSF descompactados (exploração para o leitor Swift)."""
import struct, sys
sys.path.insert(0, __file__.rsplit('/', 1)[0])
import hsf_probe

class R:
    def __init__(s, b): s.b = b; s.i = 0
    def u8(s): v = s.b[s.i]; s.i += 1; return v
    def u16(s): v = struct.unpack_from('<H', s.b, s.i)[0]; s.i += 2; return v
    def u32(s): v = struct.unpack_from('<I', s.b, s.i)[0]; s.i += 4; return v
    def i32(s): v = struct.unpack_from('<i', s.b, s.i)[0]; s.i += 4; return v
    def f(s, n=1): v = struct.unpack_from('<%df' % n, s.b, s.i); s.i += 4 * n; return v
    def raw(s, n): v = s.b[s.i:s.i + n]; s.i += n; return v

def var(r):  # 1 byte; se bit alto, mais bytes
    v = r.u8(); shift = 8; full = v
    while v & 0x80:
        v = r.u8(); full |= v << shift; shift += 8
    return full

def shell(r):
    r.u8()  # byte inicial (versão)
    sub = r.u8(); sub2 = r.u16() if sub & 0x80 else 0
    if not sub & 0x10: idx = r.u32()
    if sub2 & 0x02: lod = r.u8(); return ('NULL', hex(sub), hex(sub2))
    raise Exception('shell sub=%s sub2=%s bytes=%s' % (hex(sub), hex(sub2), r.b[r.i:r.i+60]))

def walk(body, limit=400, verbose=True):
    r = R(body); depth = 0; n = 0
    while r.i < len(body) and n < limit:
        at = r.i; op = r.u8(); n += 1
        c = chr(op) if 32 <= op < 127 else '0x%02x' % op
        info = ''
        if op == ord('('):
            L = r.u8(); info = r.raw(L).decode('latin1'); depth += 1
        elif op == ord(')'): depth -= 1
        elif op == 0x00: info = 'TERM'
        elif op == ord('%'): r.u8(); info = tuple(round(x, 4) for x in r.f(12))
        elif op == ord('}'):
            proj = r.u8(); r.u8(); r.f(11)
            if proj & 0x10: r.f(1)
            if proj & 0x20: r.f(1)
            if proj & 0x40: r.f(1)
            L = r.u8(); info = r.raw(L)
        elif op == ord('m'):
            cnt = r.u32(); items = []
            for _ in range(cnt):
                key = r.raw(4); size = r.u32(); items.append((key, r.raw(size)))
            info = items
        elif op == ord('"'):
            geo = var(r); ch = var(r); vals = []
            for bit in range(16):
                if not ch & (1 << bit): continue
                if bit in (5, 6): vals.append(('f', r.f(1)[0])); continue
                L = r.u8()
                vals.append(('rgb', tuple(r.raw(3))) if L == 0 else ('str', r.raw(L)))
            info = (hex(geo), hex(ch), vals)
        elif op == ord('q'): pass
        elif op == ord('S'):
            info = shell(r)
        elif op == ord('U'):
            L = r.u16()
            if L == 0xffff: L = r.u32()
            info = r.raw(L)[:60]
        elif op == ord('-'):
            L = r.u8()
            if L == 0xff: L = r.u8()
            info = r.raw(L)
        else:
            print(f'{at:6d} {"  "*depth}{c}  ?? próximos bytes {body[r.i:r.i+40]}'); return
        if verbose: print(f'{at:6d} {"  "*depth}{c}  {info}')

if __name__ == '__main__':
    pre, body, _ = hsf_probe.load(sys.argv[1])
    walk(body, int(sys.argv[2]) if len(sys.argv) > 2 else 400)
