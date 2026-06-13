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


def run_player(raw_path, syms, player_raw, vgm_bytes):
    disk = make_disk({2: 3, 3: 4, 4: 0xFFFF},
                     vgm_bytes,
                     [make_dent("MUSIC   VGM", START_CLSTR, len(vgm_bytes))])
    cpu = setup(raw_path, syms, disk)
    player = open(player_raw, "rb").read()
    cpu.mem[PLAYER_ORG : PLAYER_ORG + len(player)] = player
    cpu.io_in[0x80] = lambda c: 0x00  # YM2203ステータス: BUSYなし

    def basic_exit(c):
        raise Trap("BASIC_EXIT", c)  # JP BASIC 到達=クリーン終了

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

    print()
    if all(results):
        print(f"test_vgmplay: 全{len(results)}項目PASS")
    else:
        print(f"test_vgmplay: {sum(1 for r in results if not r)}項目FAIL")
        sys.exit(1)


if __name__ == "__main__":
    main()
