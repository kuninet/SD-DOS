# シリアル受信サンプル(SDRECV / YMODEM)

`samples/SDRECV.asm` は、PC-8001 の外付け RS-232C ボード([kuninet/PC8001ext232C](https://github.com/kuninet/PC8001ext232C))Ch1 から **YMODEM(batch)プロトコルでファイルを受信し、そのまま SD カードへ書き込む**サンプルである。

母艦側は `lrzsz`(Homebrew で導入可)の `sb -k` で送るだけで完結する。SD-DOS の書きストリーム API(`STRM_CREATE` / `STRM_WRITE` / `STRM_FCLOSE`、PR #65 で追加)を介してファイルが作られる。

## 想定するハード

- 外付け 232C ボード: 8251 ×2
- Ch1: I/O ポート
  - `0C0H` = データ レジスタ(読み=受信、書き=送信)
  - `0C1H` = コマンド/ステータス レジスタ
- 受信割り込み:
  - モード 2 ベクタ `08H`(Ch1)→ CPU は `(I << 8) | 08H` = **`8008H`** に格納されたアドレスへジャンプ
  - 通常は N-BASIC ROM 内の標準シリアル処理アドレスが入っており、SDRECV はこれを**一時的に自前 ISR へ書き換え**、終了時に**元へ復元**する

## ボーレート

ボード側のボーレートジェネレータで **9600 8N1** を想定。8251 の初期化は ×16 クロック、8 ビット、ストップ 1、パリティ無し。

## 使い方

### 母艦(Mac)側

```sh
brew install lrzsz
# USB シリアル変換 + 232C ボード を 9600 8N1 で接続
# 一度 tio などで接続を確認しておくと安心
tio -b 9600 -d 8 -s 1 -p none /dev/tty.usbserial-XXXX
# Ctrl-T q で抜ける

# 送信は sb -k で:
sb -k file.vgm </dev/tty.usbserial-XXXX >/dev/tty.usbserial-XXXX
```

`sb -k` は YMODEM(1K ブロック対応)で送信する。母艦は受信側からの **`C`(0x43)を見てから**ヘッダブロックを送り始めるので、PC-8001 側で SDRECV を起動してから `sb -k` を実行する。

### PC-8001 側

```
LOAD "SDRECV.CMT"
```

機械語モニタで **`G9000`** で起動(`CMD R` ではなくモニタの Go コマンド)。

```
-- SDRECV YMODEM --
```

の表示が出たら受信待ち。SDRECV は `C` を定期送出して母艦に CRC モードでの転送を要求する。母艦で `sb -k file.vgm` を実行すると転送が始まり、画面に

```
RECV: FILE.VGM
DONE
```

と表示されて BASIC に戻る。受信中に **CAN(0x18)**が 1 個でも来た場合は中断扱いとなり、`CANCELED` を表示してオープン中のファイルを `STRM_FCLOSE` で閉じてから BASIC へ戻る。

転送後、ファイルは現在の作業ディレクトリに 8.3 形式の大文字ファイル名で保存される。たとえば `file.vgm` を送れば `FILE.VGM` になる。続けて `VGMPLAY.CMT` をロードして VGM を再生できる。

## 内部構成

| 部品 | 役割 |
|---|---|
| `INSTALL_ISR` | 8251 受信を一旦停止 → `8008H` のベクタを `SAVED_VEC` に退避 → 自前 `ISR` を書き込み → 8251 をリセット → モード(`4EH`)→ コマンド(`15H` = RxE+TxEN+ER)で受信を有効化 |
| `UNINSTALL_ISR` | 8251 受信を `CMD_RXOFF` で停止 → `SAVED_VEC` を `8008H` に書き戻し |
| `ISR` | `0C1H` ステータス確認(エラーは ER でクリア)→ `0C0H` から 1 バイト読み出し → リングバッファ末尾へ格納。満杯なら破棄+`RBUF_OVR++` |
| `GETC` / `CHECK_RX` | ブロッキング / ノンブロッキングの取り出し |
| `PUTC` | `0C1H` の TxRDY を待って `0C0H` へ送信 |
| `YMAIN` | YMODEM 状態遷移。ヘッダ(block 0)受信 → `STRM_CREATE` → データブロック loop(payload を `STRM_WRITE`)→ `EOT` → 終端 block 0 → `STRM_FCLOSE` |
| `YM_RECV_PAYLOAD` | seq+~seq+payload+CRC を受信、CRC-16/XMODEM(poly 1021H, init 0)で検査。1024B 対応。フレームは必ず最後まで読んで ring と同期 |
| `YM_PARSE_HEADER` | block 0 の `filename\0size\0` をパース。filename を大文字化して `FNAME` に、size を 32 bit `REMAIN` にデコード |
| `YM_WRITE_BLOCK` | `BLKBUF` の payload を `STRM_WRITE` で SD に書き、`REMAIN` を減らす。`REMAIN=0` になったら以降の padding は捨てる |

リングバッファは `0A000H` から 256 バイト(8 ビットインデックスでラップ完結)、ブロックバッファは `0A200H` から 1024 バイト(STX フル対応)。`RBUF_W` は ISR のみが、`RBUF_R` は `GETC`/`CHECK_RX` のみが更新する。

起動: 機械語モニタ `G9000` / 終了: 受信完了で `JP BASIC`(0081H)、もしくは `CAN` 受信で中断。

## エラー時の挙動

- **CRC 不一致 / seq ミスマッチ** → `NAK`(0x15)を返し、`sb` が同じブロックを再送
- **重複ブロック**(=直前と同じ seq)→ `ACK` を返してスキップ
- **CAN ×1 以上** → 中断、`STRM_FCLOSE`(オープン済みなら)→ BASIC へ
- **未知バイト** → ループで読み捨てて次の SOH/STX/EOT/CAN を待つ

## 設計上のメモ

- **ベクタ復元は必ず行う**。終了時に復元しないと、ISR の物理アドレスが上書きされた状態で BASIC のシリアル処理がそのまま呼ばれ続けて暴走する
- **8251 のモード/コマンド値**(`4EH` / `15H`)は理論値。実機で N-BASIC が `OPEN "COM:"` 時にどんな値を書いているかを確認して必要なら調整する
- **9600 8N1**: 1 文字 ≈ 1.04 ms。PC-8001 の実効 1.84 MHz でも ISR の数十命令は十分間に合うが、画面表示(`RST 18H`)が長引くと取りこぼし得るので、**画面表示はメインループ側**、ISR は**リング格納のみ**にしている
- **SD 書き込み**は `STRM_WRITE` 内のセクタ境界(512B ごと)で発生する。MMC のビットバンギング書込は数十 ms かかるがブロック受信後の `ACK` 送信前ではなく `ACK` 送信後に行うため、`sb` の次ブロック送信中にちょうど SD 書込が走る形で自然なフロー制御になる
- **REMAIN による末尾切り詰め**: YMODEM は最終データブロックを 0x1A などで埋めて送るが、ヘッダの size を厳守して書く。VGM 等のバイナリでも余計な末尾バイトは付かない

## テスト

- **エミュ単体検証** (`scripts/test_sdrecv.py`): リングバッファ(`GETC`)の取り出し・インデックス進行・ラップ・空判定
- **エミュ往復検証** (`scripts/test_sdrecv_ymodem.py`): YMODEM フレームを Python で生成 → `GETC`/`CHECK_RX`/`PUTC` をフックして供給 → 実 ROM の `STRM_CREATE`/`STRM_WRITE`/`STRM_FCLOSE` を呼ばせて disk 辞書に書かせる → `STRM_OPEN`/`STRM_READ` で読み戻して一致確認。CRC-16 既知ベクタ、SOH 小ファイル、STX 1024B 複数ブロック、CRC エラー再送、すべて検証
- **8251 I/O と割り込み(`ISR`/`RETI`)は z80mini に I/O ポート/割り込みモデルが無いため実機検証**(母艦 `sb -k` から小ファイル → VGM 実ファイルを転送 → そのまま `VGMPLAY.CMT` で再生)

## 次にやること

- 母艦から VGM ファイルを転送 → そのまま VGMPLAY で再生 → 一連の動作確認動画
- 送信機能(SDSEND)を別途検討。SD から読んだファイルを `sz -k` 経由で母艦へ。`STRM_READ` の鏡像なので、本サンプルの逆向き
