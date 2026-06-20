# PC-8001 SD-DOS

## 本リポジトリについて
* 本リポジトリは、[chiqlappe/SD-DOS](https://github.com/chiqlappe/SD-DOS) をForkした派生版です
* 当面の目標として、SD上のファイルを少しずつ読み出せるストリームアクセス機能(コマンドまたはAPI)の追加を検討します。利用例として、FM音源などのVGM音楽ファイルをロードしながら演奏するサンプルの作成を予定しています

## このプログラムについて
* 初代PC-8001の拡張ポートに接続されたmicroSDドライブと拡張RAM(8KBバッテリバックアップRAMまたは64KB RAM)を使って、SDメモリカードの読み書きを行います
* FAT16とCMTファイルに対応
* 詳しくはMANUAL.txtを御覧ください

## ソースをアセンブルする方法
 * PC-8001エミュレータj80付属のtools80でアセンブル可能です([tools/README.md](tools/README.md) 参照)

`make`(または `java -jar tools/tools80.jar -tgt=z80 src/MAIN.asm`)

ビルド手順とディレクトリ構成は [docs/build.md](docs/build.md) を、全体の構成は [docs/architecture.md](docs/architecture.md) を参照してください。

### ビルドのバリエーション(SDドライバ)
SDアクセスの下回りは2系統から選べます。既定はビットバンギングです。上位のファイルシステム層(FS/STRM/FAT)は共通・無変更です。

| ビルド | フラグ | SDドライバ | 用途 |
|---|---|---|---|
| `make`(既定) | `USE_PICSD=FALSE` | `src/MMC.asm`(8255ビットバンギングSPI) | 既存のmicroSDドライブ |
| `make picsd` | `USE_PICSD=TRUE` | `src/MMC_PIC.asm`(D0H-D6H I/O) | [PC8001extSDRTC](https://github.com/kuninet/PC8001extSDRTC) のPIC式ドライブ |

I/O プロトコルは PC8001extSDRTC の [docs/protocol.md](https://github.com/kuninet/PC8001extSDRTC/blob/main/docs/protocol.md) を参照してください。

## リンク
* [PC-8001用 8KB拡張RAMボード](https://github.com/chiqlappe/ram8k)
* [PC-8001用 micorSDドライブ](https://github.com/chiqlappe/sdd)
* [PC-8001用 PIC式SDカード+RTCドライブ (PC8001extSDRTC)](https://github.com/kuninet/PC8001extSDRTC) — SDアクセスをPICにオフロードする外部バス直結ボード(`make picsd` で対応)
