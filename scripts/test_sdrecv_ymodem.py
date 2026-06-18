#!/usr/bin/env python3
"""SDRECVのYMODEM受信を、MAIN.rawの書きストリームAPIと連携してエミュ検証する。

  - GETC を Python キューから供給するフックに差し替え
  - PUTC を送信ログに記録するフックに差し替え
  - STRM_CREATE/STRM_WRITE/STRM_FCLOSE は MAIN.raw の実コード(6014/6017/601A)
    を通して走らせ、WRITE_SCTR フックで `disk` 辞書へ書き戻す
  - 模擬YMODEMストリーム(ブロック0+データブロック+EOT+終端ブロック0)を
    流し込み、disk に書かれたファイル内容と送信ACK列を検証する

使い方:
    make test
"""
import struct
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from test_multicluster import load_symbols
from test_stream_api import setup
from z80mini import Trap

PLAYER_ORG = 0x9000

SOH = 0x01
STX = 0x02
EOT = 0x04
ACK = 0x06
NAK = 0x15
CAN = 0x18
CRC_C = ord("C")


def crc16_xmodem(data: bytes) -> int:
    crc = 0
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            if crc & 0x8000:
                crc = ((crc << 1) ^ 0x1021) & 0xFFFF
            else:
                crc = (crc << 1) & 0xFFFF
    return crc


def make_block(seq: int, payload: bytes, use_stx: bool) -> bytes:
    marker = STX if use_stx else SOH
    n = 1024 if use_stx else 128
    if len(payload) < n:
        payload = payload + b"\x1A" * (n - len(payload))
    elif len(payload) > n:
        raise ValueError("payload too large")
    crc = crc16_xmodem(payload)
    return bytes([marker, seq & 0xFF, (~seq) & 0xFF]) + payload + bytes([crc >> 8, crc & 0xFF])


def make_header_block(filename: str, size: int) -> bytes:
    payload = filename.encode("ascii") + b"\x00" + str(size).encode("ascii") + b"\x00"
    return make_block(0, payload, use_stx=False)


def make_empty_header() -> bytes:
    return make_block(0, b"\x00", use_stx=False)


def build_ymodem_stream(filename: str, content: bytes, use_stx: bool = False) -> bytes:
    """`sb -k file` 相当の YMODEM フレーム列を生成"""
    blksize = 1024 if use_stx else 128
    s = bytearray()
    s += make_header_block(filename, len(content))
    seq = 1
    for i in range(0, len(content), blksize):
        s += make_block(seq, content[i:i + blksize], use_stx)
        seq = (seq + 1) & 0xFF
    s += bytes([EOT])
    s += make_empty_header()
    return bytes(s)


# ---- CRC16 known vectors ----
def test_crc16_python():
    """Python版CRC16の単体確認(Z80側比較の前提)"""
    assert crc16_xmodem(b"") == 0x0000
    assert crc16_xmodem(b"123456789") == 0x31C3


def run_ymodem(main_raw, main_sym, sdrecv_raw, sdrecv_sym, stream, disk):
    cpu = setup(main_raw, main_sym, disk, writable=True)
    player = open(sdrecv_raw, "rb").read()
    cpu.mem[PLAYER_ORG:PLAYER_ORG + len(player)] = player

    GETC = sdrecv_sym["GETC"]
    PUTC = sdrecv_sym["PUTC"]
    CHECK_RX = sdrecv_sym["CHECK_RX"]
    YMAIN = sdrecv_sym["YMAIN"]
    CY = 0x01

    in_queue = list(stream)
    sent = bytearray()

    def getc_hook(c):
        if not in_queue:
            raise Trap("GETC underflow", c)
        c.a = in_queue.pop(0)
        return True

    def check_rx_hook(c):
        # 非ブロッキング読み: 即座に1バイト供給(タイムアウト経路は使わない)
        if in_queue:
            c.a = in_queue.pop(0)
            c.f &= ~CY
        else:
            c.f |= CY
        return True

    def putc_hook(c):
        sent.append(c.b)
        return True

    cpu.hooks[GETC] = getc_hook
    cpu.hooks[CHECK_RX] = check_rx_hook
    cpu.hooks[PUTC] = putc_hook

    cpu.call(YMAIN)
    return cpu, sent


def main():
    main_raw, main_sym_path, sdrecv_raw, sdrecv_sym_path = sys.argv[1:5]
    main_sym = load_symbols(main_sym_path)
    sdrecv_sym = load_symbols(sdrecv_sym_path)

    results = []

    def check(name, cond, detail=""):
        print(f"  {'PASS' if cond else 'FAIL'}: {name}" + (f" ({detail})" if detail else ""))
        results.append(cond)

    test_crc16_python()

    # ---- CRC16 Z80側 ----
    print("=== Z80側CRC16(既知ベクタ)")
    from z80mini import Z80
    cpu = Z80()
    raw = open(sdrecv_raw, "rb").read()
    cpu.mem[PLAYER_ORG:PLAYER_ORG + len(raw)] = raw

    def z80_crc(data: bytes) -> int:
        cpu.set_hl(0)
        for b in data:
            cpu.a = b
            cpu.call(sdrecv_sym["CRC16_UPDATE"])
        return cpu.get_hl()

    check("CRC16(empty)=0x0000", z80_crc(b"") == 0x0000)
    val = z80_crc(b"123456789")
    check("CRC16(123456789)=0x31C3", val == 0x31C3, f"got={val:04X}")
    val = z80_crc(b"A")
    expected = crc16_xmodem(b"A")
    check(f"CRC16(A)=0x{expected:04X}", val == expected, f"got={val:04X}")

    # ---- 小ファイル(SOH 128B 1ブロック)の往復 ----
    print("=== YMODEM往復: 小ファイル(SOH 128B)")
    content = bytes((i * 13 + 7) % 251 for i in range(80))  # 80B (1 SOH block, padded)
    stream = build_ymodem_stream("OUT.BIN", content, use_stx=False)
    disk = empty_disk_dict()
    cpu, sent = run_ymodem(main_raw, main_sym, sdrecv_raw, sdrecv_sym, stream, disk)

    # FNAMEは "OUT.BIN" を大文字化(既に大文字)
    fname_bytes = cpu.mem[sdrecv_sym["FNAME"]:sdrecv_sym["FNAME"] + 8]
    check("FNAMEに'OUT.BIN'が入る", fname_bytes[:7] == b"OUT.BIN",
          f"FNAME={bytes(fname_bytes[:8])!r}")

    # disk に書かれたファイルを読み戻す
    got, ok = read_from_disk(main_raw, main_sym, disk, "OUT.BIN", len(content))
    check("読み戻しサイズ一致", got is not None and len(got) == len(content),
          f"len={len(got) if got else 0}")
    check("読み戻し内容一致(REMAINで切り詰め)", got == content)

    # 送信列の確認: 'C'(s), ACK(header), 'C'(again for data),
    # ACK(data block), ACK(EOT), 'C'(again), ACK(trailing header)
    ack_count = sent.count(ACK)
    c_count = sent.count(CRC_C)
    nak_count = sent.count(NAK)
    check("ACKが4回以上(header/data/EOT/trailing)", ack_count >= 4,
          f"ACK={ack_count} 'C'={c_count} NAK={nak_count}")
    check("NAKが0", nak_count == 0)

    # ---- 中ファイル(STX 1024B + α, パディング除去) ----
    print("=== YMODEM往復: 中ファイル(STX 1024B複数ブロック)")
    content2 = bytes((i * 37 + 19) % 251 for i in range(1500))
    stream2 = build_ymodem_stream("MID.DAT", content2, use_stx=True)
    disk2 = empty_disk_dict()
    cpu2, sent2 = run_ymodem(main_raw, main_sym, sdrecv_raw, sdrecv_sym, stream2, disk2)
    got2, _ = read_from_disk(main_raw, main_sym, disk2, "MID.DAT", len(content2))
    check("STX往復: サイズ一致(パディングが残バイトで切り詰め)",
          got2 is not None and len(got2) == len(content2),
          f"len={len(got2) if got2 else 0}")
    check("STX往復: 内容一致", got2 == content2)
    check("STX: NAK=0", sent2.count(NAK) == 0)

    # ---- CRCエラー1回でNAK→再送→成功 ----
    print("=== CRCエラー時にNAKを返し、再送ブロックを受理する")
    content3 = b"X" * 50
    s3 = bytearray()
    s3 += make_header_block("BAD.DAT", len(content3))
    # わざとCRCを壊した1ブロック目
    good = make_block(1, content3, use_stx=False)
    bad = bytearray(good)
    bad[-1] ^= 0xFF  # CRC lo を壊す
    s3 += bad
    s3 += good  # 再送(正しいCRC)
    s3 += bytes([EOT])
    s3 += make_empty_header()
    disk3 = empty_disk_dict()
    cpu3, sent3 = run_ymodem(main_raw, main_sym, sdrecv_raw, sdrecv_sym, bytes(s3), disk3)
    got3, _ = read_from_disk(main_raw, main_sym, disk3, "BAD.DAT", len(content3))
    check("再送後の内容が一致", got3 == content3, f"got={got3[:20] if got3 else None!r}")
    check("NAK >= 1", sent3.count(NAK) >= 1, f"NAK={sent3.count(NAK)}")

    print()
    if all(results):
        print(f"test_sdrecv_ymodem: 全{len(results)}項目PASS")
    else:
        print(f"test_sdrecv_ymodem: {sum(1 for r in results if not r)}項目FAIL")
        sys.exit(1)


# ---- disk helpers (test_stream_api と同じ流儀) ----
SCTR_SIZE = 512


def empty_disk_dict():
    return {
        1: bytes(SCTR_SIZE),  # FAT
        5: bytes(SCTR_SIZE),  # ROOT
    }


def read_from_disk(main_raw, main_sym, disk, fname, expected_size):
    """SDに書かれたファイルをSTRM_OPEN/READで読み戻す(test_stream_apiの流儀)"""
    from test_stream_api import setup, set_fname, STRM_OPEN, STRM_READ, CY
    cpu2 = setup(main_raw, main_sym, disk, writable=False)
    set_fname(cpu2, fname)
    cpu2.call(STRM_OPEN)
    if cpu2.f & CY:
        return None, False
    got = bytearray()
    try:
        for _ in range(expected_size + 1):
            cpu2.call(STRM_READ)
            if cpu2.f & CY:
                break
            got.append(cpu2.a)
    except Trap:
        return bytes(got), False
    return bytes(got), True


if __name__ == "__main__":
    main()
