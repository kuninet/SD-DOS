#!/usr/bin/env python3
"""複数クラスタにまたがるファイルの逐次読み(FETCH_1BYTE/INC_FP)の挙動を確認する。

アセンブル済みのSD-DOS本体(MAIN.raw)をZ80インタプリタで実行し、
SDセクタ読み込み(READ_SCTR)だけをホスト側のディスクイメージで肩代わりする。
FAT関連のワークを直接設定したうえでPREP_READとFETCH_1BYTEを実コードのまま動かし、
取得バイト列が期待値と一致するかを確認する。

使い方:
    make test
    (または make list の後に
     python3 scripts/test_multicluster.py build/MAIN.raw build/MAIN.sym)
"""
import re
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from z80mini import Z80, Trap

SCTR_SIZE = 512
SCTRS_PER_CLSTR = 2  # 1クラスタ=2セクタにしてクラスタ跨ぎを起こしやすくする
FAT_SCTR = 1
DATA_SCTR = 10
START_CLSTR = 2


def load_symbols(path):
    syms = {}
    for m in re.finditer(r"([0-9A-F]{4}) (\S+)", open(path).read()):
        syms[m.group(2)] = int(m.group(1), 16)
    return syms


def make_disk(chain, content):
    """FATチェーンとファイル内容からセクタ#→512バイトのディスクを作る"""
    disk = {}
    fat = bytearray(SCTR_SIZE)
    for clstr, nxt in chain.items():
        fat[clstr * 2] = nxt & 0xFF
        fat[clstr * 2 + 1] = nxt >> 8
    disk[FAT_SCTR] = bytes(fat)
    clusters = []
    c = START_CLSTR
    while c in chain:
        clusters.append(c)
        if chain[c] == 0xFFFF:
            break
        c = chain[c]
    pos = 0
    for c in clusters:
        for s in range(SCTRS_PER_CLSTR):
            sct = DATA_SCTR + (c - START_CLSTR) * SCTRS_PER_CLSTR + s
            disk[sct] = bytes(content[pos : pos + SCTR_SIZE].ljust(SCTR_SIZE, b"\x00"))
            pos += SCTR_SIZE
    return disk


def setup(raw_path, syms, disk, file_size, log):
    cpu = Z80()
    cpu.mem[0x6000 : 0x6000 + len(open(raw_path, "rb").read())] = open(raw_path, "rb").read()

    def read_sctr(c):
        sct = int.from_bytes(bytes(c.mem[syms["DW0"] : syms["DW0"] + 4]), "little")
        dest = c.get_hl()
        data = disk.get(sct, bytes(SCTR_SIZE))
        c.mem[dest : dest + SCTR_SIZE] = data
        log.append((sct, dest, c.mem[syms["FP_CLSTR"]] | (c.mem[syms["FP_CLSTR"] + 1] << 8),
                    c.mem[syms["FP_CLSTR_SN"]] | (c.mem[syms["FP_CLSTR_SN"] + 1] << 8)))
        return True  # RET相当

    def err(name):
        def hook(c):
            raise Trap(name, c)
        return hook

    cpu.hooks[syms["READ_SCTR"]] = read_sctr
    cpu.hooks[syms["ERR"]] = err("ERR(メッセージ表示エラー)")
    cpu.hooks[0x3BF9] = err("ERROR(N-BASICエラー)")  # ERROR EQU 03BF9H

    # FAT16関連ワークを直接設定する(MOUNT相当の結果)
    cpu.mem[syms["SCTRS_PER_CLSTR"]] = SCTRS_PER_CLSTR
    for name, val in (("FAT_SCTR", FAT_SCTR), ("DATA_SCTR", DATA_SCTR), ("ROOT_SCTR", 5)):
        cpu.mem[syms[name] : syms[name] + 4] = val.to_bytes(4, "little")
    cpu.mem[syms["FAT_SIZE"] : syms["FAT_SIZE"] + 2] = (0x20).to_bytes(2, "little")
    cpu.mem[syms["TGT_CLSTR"] : syms["TGT_CLSTR"] + 2] = START_CLSTR.to_bytes(2, "little")
    sz = syms["DIR_ENTRY"] + syms["IDX_SIZE"]
    cpu.mem[sz : sz + 4] = file_size.to_bytes(4, "little")

    cpu.call(syms["INIT_DW"])
    cpu.call(syms["INIT_BFFR"])
    return cpu


def run_case(name, raw_path, syms, chain, file_size):
    print(f"=== {name}: サイズ={file_size} クラスタ鎖={chain}")
    content = bytes((i % 251) for i in range(file_size))  # 周期251(素数)でクラスタずれを検出できるようにする
    disk = make_disk(chain, content)
    log = []
    cpu = setup(raw_path, syms, disk, file_size, log)
    got = bytearray()
    try:
        cpu.call(syms["PREP_READ"])
        for _ in range(file_size):
            cpu.call(syms["FETCH_1BYTE"])
            got.append(cpu.a)
    except Trap as t:
        print(f"  {len(got)}バイト目の取得中に停止: {t.name}")
    print("  セクタ読み込みログ (セクタ#, 転送先, FP_CLSTR, FP_CLSTR_SN):")
    for sct, dest, fc, fcsn in log:
        print(f"    sector={sct:<4} dest={dest:04X} FP_CLSTR={fc:04X} FP_CLSTR_SN={fcsn}")
    ok = bytes(got) == content[: len(got)]
    if ok and len(got) == file_size:
        print(f"  結果: 全{file_size}バイト一致")
    elif ok:
        print(f"  結果: 取得できた{len(got)}バイトまでは一致(途中で停止)")
    else:
        bad = next(i for i in range(len(got)) if got[i] != content[i])
        print(f"  結果: 不一致! 最初の不一致={bad}バイト目 "
              f"(期待{content[bad]:02X} 実際{got[bad]:02X})")
    return ok, len(got)


def main():
    raw_path, sym_path = sys.argv[1], sys.argv[2]
    syms = load_symbols(sym_path)

    # ケースC: 1クラスタに収まるファイル(対照ケース)
    run_case("ケースC 1クラスタ・対照", raw_path, syms,
             {2: 0xFFFF}, file_size=1000)

    # ケースA: 3クラスタにまたがるファイル(終端はクラスタ途中)
    run_case("ケースA 3クラスタ・終端は途中", raw_path, syms,
             {2: 3, 3: 4, 4: 0xFFFF}, file_size=2 * 1024 + 612)

    # ケースB: クラスタサイズちょうどの倍数で終わるファイル
    run_case("ケースB 2クラスタ・境界ちょうどで終端", raw_path, syms,
             {2: 3, 3: 0xFFFF}, file_size=2 * 1024)


if __name__ == "__main__":
    main()
