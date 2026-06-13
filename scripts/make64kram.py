#!/usr/bin/env python3
"""LOADER64.asmとMAIN.asmのアセンブル結果(Intel HEX)から64KRAM.hexを生成する。

使い方:
    java -jar tools80.jar -tgt=z80 -hex LOADER64.asm
    java -jar tools80.jar -tgt=z80 -hex MAIN.asm
    python3 scripts/make64kram.py LOADER64.hex MAIN.hex -o 64KRAM.hex

EPROMイメージの構成:
    6000H-604BH ローダ(LOADER64.asm)
    604CH以降    SD-DOS本体(MAIN.asmの6000H-79xxHのコードを604CHへ再配置)
                ローダのコピー長BODY_LEN(18F0H)に満たない部分はFFHで埋める

本体のコードがBODY_LENを超えた場合はエラーになる。
その場合はLOADER64.asmのBODY_LENも合わせて更新すること。
"""
import argparse
import sys

ORG = 0x6000
LOADER_LEN = 0x4C
BODY_LEN = 0x1B00  # LOADER64.asmのBODY_LENと一致させること
RECORD_LEN = 16


def read_ihex(path):
    """Intel HEXを読み、{アドレス: バイト値}の辞書を返す"""
    mem = {}
    with open(path, "r") as f:
        for line in f:
            line = line.strip()
            if not line.startswith(":"):
                continue
            count = int(line[1:3], 16)
            addr = int(line[3:7], 16)
            rectype = int(line[7:9], 16)
            if rectype != 0:
                continue
            data = bytes.fromhex(line[9 : 9 + count * 2])
            for i, b in enumerate(data):
                mem[addr + i] = b
    return mem


def emit_ihex(image, org, out):
    """イメージをIntel HEX(大文字、CRLF、16バイト/レコード)で書き出す"""
    lines = []
    for off in range(0, len(image), RECORD_LEN):
        chunk = image[off : off + RECORD_LEN]
        addr = org + off
        rec = bytes([len(chunk), addr >> 8, addr & 0xFF, 0]) + chunk
        checksum = (-sum(rec)) & 0xFF
        lines.append(":" + (rec + bytes([checksum])).hex().upper())
    lines.append(":00000001FF")
    with open(out, "wb") as f:
        f.write(("\r\n".join(lines) + "\r\n").encode("ascii"))


def main():
    parser = argparse.ArgumentParser(description="64KRAM.hexを生成する")
    parser.add_argument("loader_hex", help="LOADER64.asmのアセンブル結果(Intel HEX)")
    parser.add_argument("main_hex", help="MAIN.asmのアセンブル結果(Intel HEX)")
    parser.add_argument("-o", "--output", default="64KRAM.hex")
    args = parser.parse_args()

    loader = read_ihex(args.loader_hex)
    main_mem = read_ihex(args.main_hex)

    loader_img = bytes(loader.get(ORG + i, 0xFF) for i in range(LOADER_LEN))
    if len([a for a in loader if a >= ORG + LOADER_LEN]):
        sys.exit(f"エラー: ローダが{LOADER_LEN:04X}Hバイトを超えている")

    body_addrs = [a for a in main_mem if ORG <= a < 0x8000]
    body_top = max(body_addrs)
    body_size = body_top - ORG + 1
    if body_size > BODY_LEN:
        sys.exit(
            f"エラー: 本体のコード長{body_size:04X}HがBODY_LEN({BODY_LEN:04X}H)を超えている。"
            "LOADER64.asmのBODY_LENとこのスクリプトを更新すること"
        )
    body_img = bytes(main_mem.get(ORG + i, 0xFF) for i in range(BODY_LEN))

    emit_ihex(loader_img + body_img, ORG, args.output)
    print(f"{args.output}: ローダ{LOADER_LEN:04X}H + 本体{body_size:04X}H (コピー長{BODY_LEN:04X}H)")


if __name__ == "__main__":
    main()
