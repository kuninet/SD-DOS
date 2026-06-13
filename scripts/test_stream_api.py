#!/usr/bin/env python3
"""ストリーム読み出しAPI(STRM_OPEN/STRM_READ/STRM_CLOSE)の動作を確認する。

アセンブル済みのSD-DOS本体をZ80インタプリタで実行し、ジャンプテーブルの
固定アドレス(6005H/6008H/600BH/600EH)経由でAPIを呼び出す。
ルートディレクトリのエントリ検索を含むオープンから、EOFまでの逐次取得、
クローズ後の状態返却までを確認する。

使い方:
    make test
"""
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from z80mini import Z80, Trap
from test_multicluster import load_symbols

SCTR_SIZE = 512
SCTRS_PER_CLSTR = 2
FAT_SCTR = 1
ROOT_SCTR = 5
DATA_SCTR = 10
START_CLSTR = 2

STRM_OPEN, STRM_READ, STRM_CLOSE = 0x6005, 0x6008, 0x600B
STRM_DIRENT, STRM_RSVD = 0x600E, 0x6011  # 600E=ディレクトリ列挙, 6011=予約
FNAME_ADR = 0x9000

CY = 0x01


def make_dent(name83, clstr, size):
    """8.3形式11バイト名のディレクトリエントリ(32バイト)を作る"""
    e = bytearray(32)
    e[0:11] = name83.encode("ascii")
    e[0x0B] = 0x20  # ATRB_FILE
    e[0x1A:0x1C] = clstr.to_bytes(2, "little")
    e[0x1C:0x20] = size.to_bytes(4, "little")
    return bytes(e)


def make_disk(chain, content, dents):
    disk = {}
    fat = bytearray(SCTR_SIZE)
    for clstr, nxt in chain.items():
        fat[clstr * 2 : clstr * 2 + 2] = nxt.to_bytes(2, "little")
    disk[FAT_SCTR] = bytes(fat)
    root = bytearray(SCTR_SIZE)
    for i, d in enumerate(dents):
        root[i * 32 : i * 32 + 32] = d
    disk[ROOT_SCTR] = bytes(root)
    pos = 0
    c = START_CLSTR
    while c in chain:
        for s in range(SCTRS_PER_CLSTR):
            sct = DATA_SCTR + (c - START_CLSTR) * SCTRS_PER_CLSTR + s
            disk[sct] = bytes(content[pos : pos + SCTR_SIZE].ljust(SCTR_SIZE, b"\x00"))
            pos += SCTR_SIZE
        if chain[c] == 0xFFFF:
            break
        c = chain[c]
    return disk


def setup(raw_path, syms, disk):
    cpu = Z80()
    raw = open(raw_path, "rb").read()
    cpu.mem[0x6000 : 0x6000 + len(raw)] = raw

    def read_sctr(c):
        sct = int.from_bytes(bytes(c.mem[syms["DW0"] : syms["DW0"] + 4]), "little")
        dest = c.get_hl()
        c.mem[dest : dest + SCTR_SIZE] = disk.get(sct, bytes(SCTR_SIZE))
        return True

    def err(name):
        def hook(c):
            raise Trap(name, c)
        return hook

    cpu.hooks[syms["READ_SCTR"]] = read_sctr

    # インクリメンタル読み: MMCブロック命令をディスクイメージで肩代わり
    block = {"sector": 0, "cursor": 0}

    def mmc_brd_cmd(c):
        phys = int.from_bytes(bytes(c.mem[syms["MMCADR0"]:syms["MMCADR0"]+4]), "little")
        block["sector"] = phys // SCTR_SIZE
        block["cursor"] = 0
        return True

    def mmc_1rd(c):
        data = disk.get(block["sector"], bytes(SCTR_SIZE))
        idx = block["cursor"]
        c.c = data[idx] if idx < SCTR_SIZE else 0
        block["cursor"] += 1
        return True

    cpu.hooks[syms["MMC_BRD_CMD"]] = mmc_brd_cmd
    cpu.hooks[syms["MMC_1RD"]] = mmc_1rd
    cpu.hooks[syms["MMC_BRD_END"]] = lambda c: True
    cpu.rst_hooks[0x18] = lambda c: c.output.append(c.a)  # 1文字出力は捕捉のみ

    # N-BASIC ROMルーチンのホスト側実装
    def cphlde(c):  # 05ED3H: HL-DEの比較(Z,CYをセット)
        hl, de = c.get_hl(), c.get_de()
        c.f = (c.f & ~0x41) | (0x40 if hl == de else 0) | (0x01 if hl < de else 0)
        return True

    def capital(c):  # 05FC1H: Aレジスタの大文字化
        if ord("a") <= c.a <= ord("z"):
            c.a -= 0x20
        return True

    cpu.hooks[0x5ED3] = cphlde
    cpu.hooks[0x5FC1] = capital
    cpu.hooks[0x5EC0] = lambda c: True  # PRTHLHEX: 表示は無視
    cpu.hooks[syms["WRITE_SCTR"]] = err("WRITE_SCTR(書き込みは発生しないはず)")
    cpu.hooks[syms["ERR"]] = err("ERR")
    cpu.hooks[0x3BF9] = err("ERROR")

    cpu.call(syms["INIT_DW"])
    cpu.call(syms["INIT_FAT16"])  # DNAME長などのワーク初期化(INIT_BFFRを含む)

    cpu.mem[syms["SCTRS_PER_CLSTR"]] = SCTRS_PER_CLSTR
    for name, val in (("FAT_SCTR", FAT_SCTR), ("DATA_SCTR", DATA_SCTR), ("ROOT_SCTR", ROOT_SCTR)):
        cpu.mem[syms[name] : syms[name] + 4] = val.to_bytes(4, "little")
    cpu.mem[syms["FAT_SIZE"] : syms["FAT_SIZE"] + 2] = (0x20).to_bytes(2, "little")
    cpu.mem[syms["ROOT_SCTR_SIZE"]] = 1
    cpu.mem[syms["WDIR_CLSTR"] : syms["WDIR_CLSTR"] + 2] = (0).to_bytes(2, "little")

    return cpu


def set_fname(cpu, name):
    data = name.encode("ascii") + b"\x00"
    cpu.mem[FNAME_ADR : FNAME_ADR + len(data)] = data
    cpu.set_hl(FNAME_ADR)


def check(results, name, cond, detail=""):
    print(f"  {'PASS' if cond else 'FAIL'}: {name}" + (f" ({detail})" if detail else ""))
    results.append(cond)


def main():
    raw_path, sym_path = sys.argv[1], sys.argv[2]
    syms = load_symbols(sym_path)
    results = []

    print("=== レイアウト確認")
    free_area = syms["FREE_AREA"]
    check(results, "FREE_AREAが8KB領域(6000H-7FFFH)に収まる", free_area <= 0x8000,
          f"FREE_AREA={free_area:04X}")

    # ケース1: 3クラスタのファイルをオープンして全バイト読む
    print("=== ケース1: オープン〜全バイト取得〜EOF〜クローズ")
    size = 2 * 1024 + 612
    content = bytes((i % 251) for i in range(size))
    disk = make_disk({2: 3, 3: 4, 4: 0xFFFF}, content,
                     [make_dent("TEST    VGM", START_CLSTR, size)])
    cpu = setup(raw_path, syms, disk)
    set_fname(cpu, "TEST.VGM")
    cpu.call(STRM_OPEN)
    check(results, "オープン成功(CY=0)", not cpu.f & CY)
    check(results, "オープン中はアクセス音抑止ON", cpu.mem[syms["SD_SND_OFF"]] != 0)
    got = bytearray()
    try:
        for _ in range(size):
            cpu.call(STRM_READ)
            if cpu.f & CY:
                break
            got.append(cpu.a)
    except Trap as t:
        check(results, "取得中に停止しない", False, t.name)
    check(results, f"全{size}バイト取得", len(got) == size)
    check(results, "取得データが一致", bytes(got) == content)
    cpu.call(STRM_READ)
    check(results, "EOFでCY=1,A=00H", bool(cpu.f & CY) and cpu.a == 0,
          f"CY={cpu.f & CY} A={cpu.a:02X}")
    cpu.call(STRM_READ)
    check(results, "EOF後の再呼び出しもCY=1,A=00H", bool(cpu.f & CY) and cpu.a == 0)
    cpu.call(STRM_CLOSE)
    check(results, "クローズ成功(CY=0)", not cpu.f & CY)
    check(results, "クローズでアクセス音抑止OFF", cpu.mem[syms["SD_SND_OFF"]] == 0)
    cpu.call(STRM_READ)
    check(results, "クローズ後はCY=1,A=01H(未オープン)", bool(cpu.f & CY) and cpu.a == 1)

    # ケース2: 存在しないファイル
    print("=== ケース2: 存在しないファイルのオープン")
    cpu = setup(raw_path, syms, disk)
    set_fname(cpu, "NOFILE.BIN")
    cpu.call(STRM_OPEN)
    check(results, "CY=1,A=01H(見つからない)", bool(cpu.f & CY) and cpu.a == 1,
          f"CY={cpu.f & CY} A={cpu.a:02X}")
    check(results, "オープン失敗でアクセス音抑止OFF", cpu.mem[syms["SD_SND_OFF"]] == 0)

    # ケース3: クラスタ境界ちょうどで終わるファイル(既存経路ではエラーになる条件)
    print("=== ケース3: クラスタ境界ちょうどで終わるファイル")
    size3 = 2 * 1024
    content3 = bytes((i % 251) for i in range(size3))
    disk3 = make_disk({2: 3, 3: 0xFFFF}, content3,
                      [make_dent("ALIGNED BIN", START_CLSTR, size3)])
    cpu = setup(raw_path, syms, disk3)
    set_fname(cpu, "ALIGNED.BIN")
    cpu.call(STRM_OPEN)
    got = bytearray()
    try:
        for _ in range(size3):
            cpu.call(STRM_READ)
            if cpu.f & CY:
                break
            got.append(cpu.a)
        stopped = False
    except Trap as t:
        stopped = True
    check(results, "最終バイトまでエラーなく取得できる",
          not stopped and len(got) == size3 and bytes(got) == content3,
          f"取得={len(got)}")
    cpu.call(STRM_READ)
    check(results, "EOFでCY=1,A=00H", bool(cpu.f & CY) and cpu.a == 0)

    # ケース4: 予約エントリ(6011H)
    print("=== ケース4: 予約エントリ(6011H)")
    cpu = setup(raw_path, syms, disk)
    cpu.call(STRM_RSVD)
    check(results, "CY=1,A=0FFH(未実装)", bool(cpu.f & CY) and cpu.a == 0xFF)

    # ケース5: ディレクトリ列挙(600EH STRM_DIRENT)
    print("=== ケース5: ディレクトリ列挙(600EH)")
    dents = [make_dent("SONG1   VGM", 2, 100),
             make_dent("SONG2   VGM", 3, 200),
             make_dent("README  TXT", 4, 50)]
    disk5 = make_disk({2: 0xFFFF, 3: 0xFFFF, 4: 0xFFFF}, b"", dents)
    cpu = setup(raw_path, syms, disk5)
    BUF = 0x9000

    def dirent(idx):
        cpu.d, cpu.e = (idx >> 8) & 0xFF, idx & 0xFF
        cpu.set_hl(BUF)
        cpu.call(STRM_DIRENT)
        if cpu.f & CY:
            return None
        s = bytearray()
        a = BUF
        while cpu.mem[a] != 0 and a < BUF + 16:
            s.append(cpu.mem[a])
            a += 1
        return s.decode("ascii", "replace")

    names = []
    for i in range(10):
        n = dirent(i)
        if n is None:
            break
        names.append(n)
    check(results, "3エントリ列挙できる", len(names) == 3, str(names))
    check(results, "0番=SONG1.VGM", bool(names) and names[0] == "SONG1.VGM")
    check(results, "1番=SONG2.VGM", len(names) > 1 and names[1] == "SONG2.VGM")
    check(results, "2番=README.TXT(拡張子整形)", len(names) > 2 and names[2] == "README.TXT")
    check(results, "範囲外でCY=1", dirent(3) is None)

    print()
    if all(results):
        print(f"test_stream_api: 全{len(results)}項目PASS")
    else:
        print(f"test_stream_api: {sum(1 for r in results if not r)}項目FAIL")
        sys.exit(1)


if __name__ == "__main__":
    main()
