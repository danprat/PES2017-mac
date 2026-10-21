#!/usr/bin/env python3
"""List the contents of a CRI CPK archive (PES 2017's dtNN_*.cpk), or find which
file a given byte offset falls in.   usage: cpkls.py <file.cpk> [offset ...]"""
import struct, sys

def unmask(b):
    """CRI's @UTF obfuscation: a running multiplier keystream over every byte."""
    m, out = 0x655F, bytearray(len(b))
    for i, x in enumerate(b):
        out[i] = x ^ (m & 0xFF); m = (m * 0x4115) & 0xFFFF
    return bytes(out)

def utf_table(data, base):
    """Parse an @UTF table at data[base:] (masked or not); returns rows as dicts."""
    if data[base:base + 4] != b'@UTF':
        data = data[:base] + unmask(data[base:])
    assert data[base:base + 4] == b'@UTF', data[base:base + 4]
    size, = struct.unpack_from('>I', data, base + 4)
    t = base + 8
    _, enc, rows_off, str_off, data_off, name_off, ncols, rowlen, nrows = struct.unpack_from('>BBHIIIHHI', data, t)
    strings = lambda o: data[t + str_off + o: data.index(b'\0', t + str_off + o)].decode('utf-8', 'replace')
    p = t + 24
    cols = []
    for _ in range(ncols):
        flags = data[p]; p += 1
        name = strings(struct.unpack_from('>I', data, p)[0]); p += 4
        typ, store = flags & 0xF, flags & 0xF0
        const = None
        if store == 0x30:
            const, p = read_val(data, p, typ, t, str_off, data_off, strings)
        cols.append((name, typ, store, const))
    rows = []
    for r in range(nrows):
        q = t + rows_off + r * rowlen; row = {}
        for name, typ, store, const in cols:
            if store == 0x50: row[name], q = read_val(data, q, typ, t, str_off, data_off, strings)
            elif store == 0x30: row[name] = const
            else: row[name] = None
        rows.append(row)
    return rows

def read_val(data, p, typ, t, str_off, data_off, strings):
    sizes = {0: 'B', 1: 'b', 2: '>H', 3: '>h', 4: '>I', 5: '>i', 6: '>Q', 7: '>q', 8: '>f'}
    if typ in sizes:
        f = sizes[typ]; v, = struct.unpack_from(f if f[0] == '>' else '>' + f, data, p)
        return v, p + struct.calcsize('>' + f.lstrip('>'))
    if typ == 0xA: return strings(struct.unpack_from('>I', data, p)[0]), p + 4
    if typ == 0xB:
        o, n = struct.unpack_from('>II', data, p); return (t + data_off + o, n), p + 8
    raise ValueError(typ)

def main():
    path = sys.argv[1]
    with open(path, 'rb') as f:
        head = f.read(0x2000)
        hdr = utf_table(head, 0x10)[0]
        toc_off, content_off = hdr['TocOffset'], hdr['ContentOffset']
        f.seek(toc_off); toc = f.read(hdr['TocSize'])
    files = utf_table(toc, 0x10)   # after 'TOC ' + 12 bytes of header
    base = min(toc_off, content_off) if toc_off else content_off
    table = sorted(((base + r['FileOffset'], r['FileSize'], (r['DirName'] or '') + '/' + r['FileName']) for r in files))
    if len(sys.argv) > 2:
        for o in map(int, sys.argv[2:]):
            hit = [e for e in table if e[0] <= o < e[0] + e[1]]
            print(o, '->', hit[0][2] + ' (starts %d, size %d, +%d)' % (hit[0][0], hit[0][1], o - hit[0][0]) if hit else '(no file)')
    else:
        print(len(table), 'files'); [print('%12d %10d %s' % e) for e in table[:200]]

main()
