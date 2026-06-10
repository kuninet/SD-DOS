# PC-8001 SD-DOS

## 本リポジトリについて
* 本リポジトリは、[chiqlappe/SD-DOS](https://github.com/chiqlappe/SD-DOS) をForkした派生版です
* 当面の目標として、SD上のファイルを少しずつ読み出せるストリームアクセス機能(コマンドまたはAPI)の追加を検討します。利用例として、FM音源などのVGM音楽ファイルをロードしながら演奏するサンプルの作成を予定しています

## このプログラムについて
* 初代PC-8001の拡張ポートに接続されたmicroSDドライブと拡張RAM(8KBバッテリバックアップRAMまたは64KB RAM)を使って、SDメモリカードの読み書きを行います
* FAT16とCMTファイルに対応
* 詳しくはMANUAL.txtを御覧ください

## ソースをアセンブルする方法
 * PC-8001エミュレータj80付属のtools80でアセンブル可能です

`java -jar tools80.jar -tgt=z80 MAIN.asm`

ビルド手順と成果物の整理方針は [docs/build.md](docs/build.md) を参照してください。

## リンク
* [PC-8001用 8KB拡張RAMボード](https://github.com/chiqlappe/ram8k)
* [PC-8001用 micorSDドライブ](https://github.com/chiqlappe/sdd)
