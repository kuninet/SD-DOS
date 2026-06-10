#!/usr/bin/env python3
"""検証用サンプル(samples/SDUMP.asm)の動作を確認する。

SD-DOS本体とサンプルをZ80インタプリタへロードし、サンプルのエントリを実行して
画面出力(RST 18Hの捕捉)に16進ダンプと読んだバイト数が現れることを確認する。

使い方:
    make test
"""
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from test_multicluster import load_symbols
from test_stream_api import setup, make_disk, make_dent, START_CLSTR

SAMPLE_ORG = 0x9000


def run_sample(raw_path, syms, sample_raw, disk):
    cpu = setup(raw_path, syms, disk)
    sample = open(sample_raw, "rb").read()
    cpu.mem[SAMPLE_ORG : SAMPLE_ORG + len(sample)] = sample
    cpu.call(SAMPLE_ORG)
    return cpu.output.decode("ascii", "replace")


def check(results, name, cond, detail=""):
    print(f"  {'PASS' if cond else 'FAIL'}: {name}" + (f" ({detail})" if detail else ""))
    results.append(cond)


def main():
    raw_path, sym_path, sample_raw = sys.argv[1], sys.argv[2], sys.argv[3]
    syms = load_symbols(sym_path)
    results = []

    size = 2 * 1024 + 612  # =0A64H
    content = bytes((i % 251) for i in range(size))
    disk = make_disk({2: 3, 3: 4, 4: 0xFFFF}, content,
                     [make_dent("SAMPLE  DAT", START_CLSTR, size)])

    print("=== SDUMP: 存在するファイル")
    out = run_sample(raw_path, syms, sample_raw, disk)
    dump_head = " ".join(f"{b:02X}" for b in content[:8])
    check(results, "先頭8バイトの16進ダンプが出力される", dump_head in out, dump_head)
    check(results, "読んだバイト数READ:0A64Hが出力される", "READ:0A64H" in out)

    print("=== SDUMP: 存在しないファイル")
    disk2 = make_disk({2: 0xFFFF}, b"", [make_dent("OTHER   BIN", START_CLSTR, 0)])
    out = run_sample(raw_path, syms, sample_raw, disk2)
    check(results, "NOT FOUNDが出力される", "NOT FOUND" in out)

    print()
    if all(results):
        print(f"test_sample: 全{len(results)}項目PASS")
    else:
        print(f"test_sample: {sum(1 for r in results if not r)}項目FAIL")
        sys.exit(1)


if __name__ == "__main__":
    main()
