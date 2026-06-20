#!/usr/bin/env python3
"""SDRECVのリングバッファ(GETC)動作を単体検証する。

8251 I/Oと割り込み(ISR/RETI)は z80mini に I/Oポート/割り込みモデルが無いため
対象外(実機検証)。本テストは GETC の取り出し・インデックス進行・ラップを確認する。

使い方:
    make test
    (または python3 scripts/test_sdrecv.py build/SDRECV.raw build/SDRECV.sym)
"""
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from z80mini import Z80, Trap
from test_multicluster import load_symbols

RBUF_ADR = 0xA000


def main():
    raw_path, sym_path = sys.argv[1], sys.argv[2]
    syms = load_symbols(sym_path)
    raw = open(raw_path, "rb").read()

    results = []

    def check(name, cond, detail=""):
        print(f"  {'PASS' if cond else 'FAIL'}: {name}" + (f" ({detail})" if detail else ""))
        results.append(cond)

    def fresh():
        cpu = Z80()
        cpu.mem[0x9000:0x9000 + len(raw)] = raw
        return cpu

    GETC = syms["GETC"]
    W = syms["RBUF_W"]
    R = syms["RBUF_R"]

    print("=== ケース1: 1バイト入った状態で取り出す")
    cpu = fresh()
    cpu.mem[RBUF_ADR + 0] = 0x55
    cpu.mem[W] = 1
    cpu.mem[R] = 0
    cpu.call(GETC)
    check("A=0x55", cpu.a == 0x55, f"A={cpu.a:02X}")
    check("Rが1に進む", cpu.mem[R] == 1)

    print("=== ケース2: 3バイトを順に取り出す")
    cpu = fresh()
    for i, b in enumerate(b"ABC"):
        cpu.mem[RBUF_ADR + 1 + i] = b
    cpu.mem[W] = 4
    cpu.mem[R] = 1
    got = bytearray()
    for _ in range(3):
        cpu.call(GETC)
        got.append(cpu.a)
    check("ABC が順に取れる", bytes(got) == b"ABC", f"got={bytes(got)!r}")
    check("Rが4に進む", cpu.mem[R] == 4)

    print("=== ケース3: 末尾ラップ(R=0xFF → 0x00)")
    cpu = fresh()
    cpu.mem[RBUF_ADR + 0xFF] = 0x99
    cpu.mem[RBUF_ADR + 0x00] = 0x77
    cpu.mem[R] = 0xFF
    cpu.mem[W] = 0x01
    cpu.call(GETC)
    check("0xFF番目を取得 A=0x99", cpu.a == 0x99, f"A={cpu.a:02X}")
    check("Rが0x00にラップ", cpu.mem[R] == 0x00)
    cpu.call(GETC)
    check("0x00番目を取得 A=0x77", cpu.a == 0x77, f"A={cpu.a:02X}")
    check("Rが0x01に進む", cpu.mem[R] == 0x01)

    print("=== ケース4: 大量データを8bitラップしながら取り出す")
    cpu = fresh()
    # ring に 0..255 を順次配置、W=0(=満杯一歩手前), R=1(空判定回避)
    for i in range(256):
        cpu.mem[RBUF_ADR + i] = i
    cpu.mem[W] = 0
    cpu.mem[R] = 1
    got = bytearray()
    for _ in range(255):  # 1〜255 を順に取り出す(W==R で停止する手前まで)
        cpu.call(GETC)
        got.append(cpu.a)
    expected = bytes(range(1, 256))
    check("1〜255 が順に取れる", bytes(got) == expected,
          f"len={len(got)} first/last={got[0] if got else -1:02X}/{got[-1] if got else -1:02X}")
    check("Rが0x00に到達(W==Rで空)", cpu.mem[R] == 0x00)

    print()
    if all(results):
        print(f"test_sdrecv: 全{len(results)}項目PASS")
    else:
        print(f"test_sdrecv: {sum(1 for r in results if not r)}項目FAIL")
        sys.exit(1)


if __name__ == "__main__":
    main()
