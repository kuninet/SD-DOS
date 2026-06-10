#!/usr/bin/env python3
"""検証ハーネスのI/O命令(OUT/IN)とVGMフィクスチャの自己テスト。

使い方:
    make test
"""
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from z80mini import Z80
from vgmfixture import make_vgm, ym2203, psg, wait, END


def check(results, name, cond, detail=""):
    print(f"  {'PASS' if cond else 'FAIL'}: {name}" + (f" ({detail})" if detail else ""))
    results.append(cond)


def main():
    results = []

    print("=== OUT/IN命令の捕捉")
    cpu = Z80()
    # LD A,42H / OUT (80H),A / IN A,(80H) / LD B,A / RET
    code = bytes([0x3E, 0x42, 0xD3, 0x80, 0xDB, 0x80, 0x47, 0xC9])
    cpu.mem[0x8000 : 0x8000 + len(code)] = code
    cpu.io_in[0x80] = lambda c: 0x7F  # ステータス: BUSYでない
    cpu.call(0x8000)
    check(results, "OUT (80H),42Hが記録される", cpu.io_log == [(0x80, 0x42)],
          str(cpu.io_log))
    check(results, "IN A,(80H)がフックの値を返す", cpu.b == 0x7F)
    cpu2 = Z80()
    cpu2.mem[0x8000 : 0x8000 + 3] = bytes([0xDB, 0x99, 0xC9])
    cpu2.call(0x8000)
    check(results, "未登録ポートのINは0FFH", cpu2.a == 0xFF)

    print("=== VGMフィクスチャ")
    data = ym2203(0x28, 0xF4) + wait(735) + psg(0x07, 0x38) + END
    vgm = make_vgm(data)
    check(results, "識別子がVgm ", vgm[0:4] == b"Vgm ")
    check(results, "バージョンが1.51", vgm[0x08:0x0C] == bytes([0x51, 0x01, 0, 0]))
    check(results, "データ開始オフセットが100H",
          int.from_bytes(vgm[0x34:0x38], "little") + 0x34 == 0x100)
    check(results, "データ部がコマンド列と一致", vgm[0x100:] == data)
    old = make_vgm(data, version=0x0101)
    check(results, "1.50未満はデータが40Hから", old[0x40:] == data and len(old) == 0x40 + len(data))

    print()
    if all(results):
        print(f"test_emu_io: 全{len(results)}項目PASS")
    else:
        print(f"test_emu_io: {sum(1 for r in results if not r)}項目FAIL")
        sys.exit(1)


if __name__ == "__main__":
    main()
