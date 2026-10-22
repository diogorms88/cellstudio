#!/usr/bin/env python3
"""Explorador de arquivos HSF (HOOPS Stream File) – lista os opcodes do fluxo descompactado."""
import struct, sys, zlib

def load(path):
    d = open(path, 'rb').read()
    assert d.startswith(b';; HSF V'), 'não é HSF'
    i = d.index(b'\n') + 1
    out = bytearray()
    # parte não compactada: I, ^T, B ... até 'Z'
    pre = []
    while i < len(d):
        op = d[i]; i += 1
        if op == ord('I'): pre.append(('I', struct.unpack_from('<I', d, i)[0])); i += 4
        elif op == 0x14:
            fmt, w, h = d[i], d[i+1] or 256, d[i+2] or 256; i += 3
            n = w * h * (3 if fmt == 0 else 4 if fmt == 1 else 1)
            pre.append(('thumb', fmt, w, h)); i += n
        elif op == ord('B'):
            i += 1  # byte de opções
            t = d[i]; i += 1
            if t == 0: pre.append(('bbox', struct.unpack_from('<6f', d, i))); i += 24
            else: pre.append(('bsphere', struct.unpack_from('<4f', d, i))); i += 16
        elif op == ord('Z'):
            z = zlib.decompressobj(); out += z.decompress(d[i:]); rest = z.unused_data
            return pre, bytes(out), rest
        elif op == ord(';'):
            j = d.index(b'\n', i); pre.append(('comment', d[i:j])); i = j + 1
        else:
            pre.append(('?', hex(op), i)); return pre, d[i-1:], b''
    return pre, b'', b''

if __name__ == '__main__':
    pre, body, rest = load(sys.argv[1])
    print(pre, 'corpo', len(body), 'resto', rest[:8])
    from collections import Counter
    print(body[:400])
