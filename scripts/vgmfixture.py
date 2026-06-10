"""テスト用のVGMファイルイメージを組み立てるヘルパ。

docs/vgm/header.md の最小解析範囲に対応したヘッダと、コマンド列から
無圧縮の.vgm相当のバイト列を作る。検証ハーネスのテストデータ用。
"""

HEADER_SIZE = 0x100  # バージョン1.51の標準ヘッダサイズ(データ開始=0x100)


def make_vgm(commands, version=0x0151, data_offset=None, ym2203_clock=0,
             ay8910_clock=0, bad_ident=False):
    """ヘッダ+コマンド列のVGMバイト列を返す。

    commands: データ部のバイト列(終了コマンド66Hを含めること)
    version: BCD表現のバージョン(例 0x0151)。0x0150未満はデータ開始40H固定
    data_offset: データ開始位置(ファイル先頭から)。省略時はバージョンで決める
    """
    if data_offset is None:
        data_offset = HEADER_SIZE if version >= 0x0150 else 0x40
    header = bytearray(data_offset)
    header[0:4] = b"Xgm " if bad_ident else b"Vgm "
    total = data_offset + len(commands)
    header[0x04:0x08] = (total - 0x04).to_bytes(4, "little")  # EOFオフセット
    header[0x08:0x0C] = version.to_bytes(4, "little")
    if version >= 0x0150:
        header[0x34:0x38] = (data_offset - 0x34).to_bytes(4, "little")
    if data_offset > 0x44:
        header[0x44:0x48] = ym2203_clock.to_bytes(4, "little")
    if data_offset > 0x74:
        header[0x74:0x78] = ay8910_clock.to_bytes(4, "little")
    return bytes(header) + bytes(commands)


def ym2203(reg, val):
    """YM2203書き込みコマンド"""
    return bytes([0x55, reg, val])


def psg(reg, val):
    """PSG(AY-3-8910)書き込みコマンド"""
    return bytes([0xA0, reg, val])


def wait(samples):
    """ウェイトコマンド(61H)"""
    return bytes([0x61]) + samples.to_bytes(2, "little")


END = bytes([0x66])
