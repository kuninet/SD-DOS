# samples/experiments — 参考・実験プログラム

Issue #68(割り込み駆動VGMプレイヤ)の試行錯誤で作った**試作・診断プログラム**の置き場です。
本採用のサンプルは以下の2本で、これらは `samples/` 直下に残してあります。

- `samples/VGMPLAY.asm` … busy-loop方式。ウェイト中に同期でSDを先読みする。実機で安定。
- `samples/VGMIRQS.asm` … VGMPLAYベースで「SDの先読みだけ」をTimer A割り込みに移した版。

ここに置いたものは**参考(reference)**です。動きますが、ボツになった試作や、ハマりの切り分けに使った診断ツールが中心です。経緯の詳細はIssueやPR、ブログ記事を参照してください。

> 結論を先に言うと、割り込み駆動(VGMIRQ系)は「動くが、長い待ちでしかSDを読めないため、結局VGMPLAYの同期読みと等価」で、明確な優位は出ませんでした。根本はSDビットバンギングの速度です。

## ボツになったVGMプレイヤ試作

| ファイル | 概要 | 顛末 |
|---|---|---|
| `VGMIRQ.asm` | HALT方式。ウェイト中に `HALT` してTimer A割り込みで起こす | SD I/O律速で実用テンポにならず却下 |
| `VGMIRQP.asm` | polling版(HALTせずTimer A flagをpolling) | VGMIRQの派生検証 |
| `VGMIRQM.asm` | VGMIRQのマーカー入りデバッグ版 | 完全ハングの切り分け用 |
| `VGMIRQF.asm` | F-1初版。ウェイト自体をTimer A tickのカウントに置換 | タイマの乱れが即テンポ崩壊を招き却下(→ VGMIRQSへ) |

## 割り込み / タイマ / チップ 診断ツール

| ファイル | 用途 |
|---|---|
| `INTTEST.asm` | **Timer A IM2割り込みの最小テスト。** 「busy-loop中に割り込みが入るか / HALT中のみか / 一切来ないか」を `A=nn B=nn` で表示。今回の無音の真因(割り込み配線ミス)を一発で暴いた。vector番号は `POKE &H9003` で総当たり可 |
| `POLL10.asm` | Timer A overflow flag の polling 単体検証(`+`/`-` 表示) |
| `TIMRSEE.asm` | OPN書込みなしでTimer A flagを観察 |
| `TATEST.asm` / `TATEST3.asm` | 27H(Timer A制御)の起動パターン総当たり |
| `OPNCHK.asm` | YM2203チップの応答(ステータス/BUSY)チェック |

## ビルド

リポジトリのトップで:

```sh
make experiments    # ここの .cmt をまとめて build/ に生成(参考用)
```

個別に試すときは、生成された `build/<名前>.cmt` を実機へ `LOAD` → モニタ `G9000` で起動します
(INTTEST等の診断ツールも同様)。
