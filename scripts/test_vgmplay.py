#!/usr/bin/env python3
"""VGM再生サンプル(samples/VGMPLAY.asm)の動作を確認する。

SD-DOS本体とプレイヤーをZ80インタプリタへロードし、テスト用VGMファイルを
SDイメージに置いて再生を実行する。音源ポート(80H/81H、0A0H/0A1H)への
出力列が期待どおりかを確認する。

使い方:
    make test
"""
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from test_multicluster import load_symbols
from test_stream_api import setup, make_disk, make_dent, START_CLSTR
from vgmfixture import make_vgm, ym2203, psg, wait, END
from z80mini import Trap

PLAYER_ORG = 0x9000
BASIC = 0x0081  # プレイヤーは終了時にRETではなくJP BASICで戻る(モニタG起動でも安全)


KEYWAIT = 0x0F75  # N-BASIC 1文字入力待ち


def run_player(raw_path, syms, player_raw, vgm_bytes, keys="1\r", dents=None, disk=None):
    if disk is None:
        if dents is None:
            dents = [make_dent("MUSIC   VGM", START_CLSTR, len(vgm_bytes))]
        disk = make_disk({2: 3, 3: 4, 4: 0xFFFF}, vgm_bytes, dents)
    cpu = setup(raw_path, syms, disk)
    player = open(player_raw, "rb").read()
    cpu.mem[PLAYER_ORG : PLAYER_ORG + len(player)] = player
    cpu.io_in[0x80] = lambda c: 0x00  # YM2203ステータス: BUSYなし

    feed = list(keys.encode("ascii"))  # メニューへ流し込むキー入力

    def keywait(c):
        c.a = feed.pop(0) if feed else 0x0D  # 尽きたらEnter→番号0→終了
        return True  # KEYWAITはA=コードでRET

    cpu.hooks[KEYWAIT] = keywait

    def basic_exit(c):
        raise Trap("BASIC_EXIT", c)  # JP BASIC 到達=クリーン終了(0入力)

    cpu.hooks[BASIC] = basic_exit
    try:
        cpu.call(PLAYER_ORG)
    except Trap as t:
        if "BASIC_EXIT" not in t.name:
            raise
    sound = [(p, v) for p, v in cpu.io_log if p in (0x80, 0x81, 0xA0, 0xA1)]
    return sound, cpu.output.decode("ascii", "replace")


def check(results, name, cond, detail=""):
    print(f"  {'PASS' if cond else 'FAIL'}: {name}" + (f" ({detail})" if detail else ""))
    results.append(cond)


def main():
    raw_path, sym_path, player_raw = sys.argv[1], sys.argv[2], sys.argv[3]
    syms = load_symbols(sym_path)
    results = []

    print("=== ケース1: YM2203+PSG混在、読み飛ばし、データブロック")
    data = (ym2203(0x2D, 0x00) + ym2203(0x28, 0xF4) + wait(5)
            + psg(0x07, 0x38)
            + bytes([0x5A, 0x12, 0x34])              # YM3812(読み飛ばし2バイト)
            + bytes([0x70])                          # 短いウェイト
            + bytes([0x67, 0x66, 0x00, 3, 0, 0, 0, 0xAA, 0xBB, 0xCC])  # データブロック3バイト
            + ym2203(0xB0, 0x33) + bytes([0x62]) + END)
    sound, out = run_player(raw_path, syms, player_raw, make_vgm(data))
    expect = [(0x80, 0x2D), (0x81, 0x00), (0x80, 0x28), (0x81, 0xF4),
              (0xA0, 0x07), (0xA1, 0x38), (0x80, 0xB0), (0x81, 0x33)]
    check(results, "音源ポートへの出力列が期待どおり", sound == expect, str(sound))
    check(results, "正常終了(VGM END)", "VGM END" in out)

    print("=== ケース2: バージョン1.50未満(データ開始40H固定)")
    data = ym2203(0x28, 0x01) + END
    sound, out = run_player(raw_path, syms, player_raw, make_vgm(data, version=0x0101))
    check(results, "旧ヘッダでも再生できる", sound == [(0x80, 0x28), (0x81, 0x01)], str(sound))
    check(results, "正常終了(VGM END)", "VGM END" in out)

    print("=== ケース3: VGMでないファイル")
    sound, out = run_player(raw_path, syms, player_raw, make_vgm(END, bad_ident=True))
    check(results, "NOT VGMで停止し音源出力なし", "NOT VGM" in out and sound == [],
          f"out={out.strip()!r}")

    print("=== ケース4: 終了コマンドなしでEOF")
    data = ym2203(0x01, 0x02)  # 66Hなし
    sound, out = run_player(raw_path, syms, player_raw, make_vgm(data))
    check(results, "EOFを正常終了として扱う",
          sound == [(0x80, 0x01), (0x81, 0x02)] and "VGM END" in out)

    print("=== ケース5: 未知のコマンドで停止")
    data = ym2203(0x01, 0x02) + bytes([0x65]) + ym2203(0x03, 0x04) + END
    sound, out = run_player(raw_path, syms, player_raw, make_vgm(data))
    check(results, "BAD COMMANDで停止し以降の出力なし",
          "BAD COMMAND" in out and sound == [(0x80, 0x01), (0x81, 0x02)],
          str(sound))

    print("=== ケース6: 複数VGMから番号2を選んで再生")
    from test_stream_api import (SCTR_SIZE, FAT_SCTR, ROOT_SCTR, DATA_SCTR,
                                 SCTRS_PER_CLSTR)
    song1 = make_vgm(ym2203(0x11, 0x11) + END)
    song2 = make_vgm(ym2203(0x22, 0x22) + END)
    disk6 = {}
    fat = bytearray(SCTR_SIZE)
    fat[2 * 2:2 * 2 + 2] = (0xFFFF).to_bytes(2, "little")
    fat[5 * 2:5 * 2 + 2] = (0xFFFF).to_bytes(2, "little")
    disk6[FAT_SCTR] = bytes(fat)
    root = bytearray(SCTR_SIZE)
    root[0:32] = make_dent("SONG1   VGM", 2, len(song1))
    root[32:64] = make_dent("SONG2   VGM", 5, len(song2))
    disk6[ROOT_SCTR] = bytes(root)

    def place(clstr, content):
        for s in range(SCTRS_PER_CLSTR):
            sct = DATA_SCTR + (clstr - 2) * SCTRS_PER_CLSTR + s
            disk6[sct] = bytes(content[s * SCTR_SIZE:(s + 1) * SCTR_SIZE]
                               .ljust(SCTR_SIZE, b"\x00"))
    place(2, song1)
    place(5, song2)
    sound, out = run_player(raw_path, syms, player_raw, b"", keys="2\r", disk=disk6)
    check(results, "一覧にSONG1/SONG2が出る",
          "1: SONG1.VGM" in out and "2: SONG2.VGM" in out, out.strip())
    check(results, "番号2でSONG2が再生される",
          sound == [(0x80, 0x22), (0x81, 0x22)], str(sound))

    print()
    if all(results):
        print(f"test_vgmplay: 全{len(results)}項目PASS")
    else:
        print(f"test_vgmplay: {sum(1 for r in results if not r)}項目FAIL")
        sys.exit(1)


if __name__ == "__main__":
    main()
