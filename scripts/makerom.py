#!/usr/bin/env python3
"""EPROM書き込み用のROMイメージを生成する。

ビルドしたIntel HEX(64KRAM.hexなど)からCPUアドレス6000H-7FFFHの8KBを
切り出し、ターゲットEPROMの容量に合わせたデバイス先頭(0000H)基準の
イメージ(.binと.hex)を生成する。

使い方:
    python3 scripts/makerom.py build/64KRAM.hex --device 27C256 -o build/rom/64KRAM-27C256
    (make rom で全ターゲット分を一括生成できる)

容量が8KBを超えるデバイスでは、既定で8KBブロックを全域へミラー(繰り返し)
配置する。拡張ROMソケット側で上位アドレス線がどう固定されていても同じ
内容が見えるため安全である。--offsetを指定するとその位置への単独配置に
なる(他はFFHで埋める)。
"""
import argparse
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from make64kram import read_ihex, emit_ihex

CPU_ORG = 0x6000  # SD-DOSが使うCPUアドレスの先頭
WINDOW = 0x2000   # 拡張ROM領域の大きさ(8KB)

DEVICES = {
    "27C64": 8192,
    "28C64": 8192,
    "27C128": 16384,
    "27C256": 32768,
    "28C256": 32768,
    "27C512": 65536,
    "W27C512": 65536,
}


def parse_int(text):
    return int(text, 0)


def main():
    parser = argparse.ArgumentParser(description="EPROM書き込み用ROMイメージを生成する")
    parser.add_argument("input_hex", help="入力Intel HEX(64KRAM.hexなど)")
    parser.add_argument("--device", choices=sorted(DEVICES),
                        help="ターゲットEPROM(容量をこの表から決める)")
    parser.add_argument("--size", type=parse_int,
                        help="ROM容量をバイト数で直接指定する(--deviceの代わり)")
    parser.add_argument("--offset", type=parse_int, default=None,
                        help="8KBブロックの配置位置。省略時は全域へミラー配置")
    parser.add_argument("-o", "--output", required=True,
                        help="出力ベース名(.binと.hexを生成する)")
    args = parser.parse_args()

    if args.device:
        size = DEVICES[args.device]
    elif args.size:
        size = args.size
    else:
        sys.exit("エラー: --device または --size を指定すること")
    if size < WINDOW:
        sys.exit(f"エラー: 容量{size}が8KB({WINDOW})より小さい")

    mem = read_ihex(args.input_hex)
    window = bytes(mem.get(CPU_ORG + i, 0xFF) for i in range(WINDOW))
    if all(b == 0xFF for b in window):
        sys.exit(f"エラー: {args.input_hex}の6000H-7FFFHにデータがない")
    outside = [a for a in mem if not CPU_ORG <= a < CPU_ORG + WINDOW]
    if outside:
        print(f"注意: 6000H-7FFFHの外のデータ({len(outside)}バイト)はROMイメージに含めない")

    if args.offset is None:
        pages = (size + WINDOW - 1) // WINDOW
        image = (window * pages)[:size]
        layout = f"ミラー配置({pages}面)" if pages > 1 else "そのまま配置"
    else:
        if args.offset < 0 or args.offset + WINDOW > size:
            sys.exit(f"エラー: --offset {args.offset:#06X} が容量{size:#06X}に収まらない")
        buf = bytearray(b"\xff" * size)
        buf[args.offset : args.offset + WINDOW] = window
        image = bytes(buf)
        layout = f"オフセット{args.offset:04X}Hへ単独配置"

    with open(args.output + ".bin", "wb") as f:
        f.write(image)
    emit_ihex(image, 0, args.output + ".hex")
    print(f"{args.output}.bin/.hex: {size}バイト ({layout})")


if __name__ == "__main__":
    main()
