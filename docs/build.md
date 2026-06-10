# ビルド手順とディレクトリ構成の整理方針

## 目的
この文書は、SD-DOSのビルド手順、成果物、外部ツール、ディレクトリ構成をまとめる。

## ビルド手順
`tools/tools80.jar`を配置したうえで(入手方法は`tools/README.md`を参照)、Makefileでビルドする。

```sh
make          # build/ に MAIN.cmt、IPL.cmt、64KRAM.hex を生成する
make test     # 回帰テスト(scripts/test_multicluster.py)を実行する
make list     # アセンブルリスト(MAIN.asm.log.asz)とシンボル(MAIN.sym)を build/ に生成する
make verify-orig  # オリジナル成果物とのバイト一致確認(複数クラスタ読み修正前のコード専用)
make clean    # build/ を削除する
```

Javaのパスは`make JAVA=/path/to/java`のように変数で指定できる。tools80(Release 6.50、Ver 6.6.68)で、改変前のソースから3つの成果物すべてがオリジナルとバイト一致することを確認済みである。

複数クラスタ読みのバグ修正以降はコードがオリジナルと意図的に異なるため、`make verify-orig`は一致しない。機能の回帰確認には`make test`を使う。

tools80を直接実行する場合は次のとおり。アセンブル対象の指定オプションは`-tgt=z80`である。出力はソースファイルと同じディレクトリ(`src/`)に書かれる。

```sh
java -jar tools/tools80.jar -tgt=z80 src/MAIN.asm
```

出力は無指定でMONITOR形式のCMTファイルになり、`-hex`(Intel HEX)、`-raw`(ベタイメージ)、`-debug`(ログ出力)のオプションも使える。tools80は実行中に`type 'OK'`の確認入力を求めることがあるため、Makefileでは`printf 'OK\n'`を標準入力へ渡している。

`64KRAM.hex`は、復元したローダソース`src/LOADER64.asm`と`src/MAIN.asm`のアセンブル結果(Intel HEX)を`scripts/make64kram.py`で合成して生成する(`make`が自動で行う)。`MAIN.asm`の出力には`EXT.asm`由来の`0C000H`ブロック(拡張コマンド)も含まれるが、EPROMイメージには`6000H`〜`7FFFH`の範囲だけを合成する。本体のコード長がローダのコピー長`BODY_LEN`(現在`1A00H`)を超えた場合は、`LOADER64.asm`と`scripts/make64kram.py`の両方の定数を更新する必要がある(スクリプトがエラーで検出する)。

`MAIN.asm.log.asz`の先頭には`Asm2Hex : Version 0.7.2`とあり、原作者は古い版のtools80を使っていたと見られるが、現行のr6_50で同一の出力が得られる。

## 外部ツールの確認結果
`tools80.jar`はリポジトリ内には含まれていない。OUT of STANDARDのPC-8001ページから入手する。

* ページ: http://upd780c1.g1.xrea.com/pc-8001/index.html
* tools80: `bin/tools80_r6_50.lzh`(確認済み)
* エミュレータ候補: `j80`(挙動確認用。導入は別途)

版についての注意:
* r6_50(Ver 6.6.68)で問題なくアセンブルできる
* r6_44(Ver 6.6.29)では`SET_DATETIME`のような`SET`で始まるラベルをオペランドに書くと`Missing Operand`エラーになる。Ver 6.6.17で追加された`LD r, SET n,(IX+d)`形式への対応の影響と見られ、r6_50では解消されている。r6_44以前は使わないこと

実行環境:
* Java実行環境があれば動くため、macOSに限らずUNIX系やWindowsでもビルドできる
* macOSではHomebrewの`openjdk`(管理者権限不要)で確認した。`/opt/homebrew/opt/openjdk/bin/java`
* `.lzh`の展開もHomebrewの`lhasa`で確認した(`lha x tools80_r6_50.lzh`)

## オリジナル由来の成果物
オリジナルリポジトリ由来のビルド成果物は、自前ビルドの成果物(`build/`、git管理外)と区別するため、`dist/original/`に保存している。

* `64KRAM.hex`
* `MAIN.cmt`
* `IPL.cmt`
* `SD_DOS_100119.wav`
* `SD_DOS_200308.wav`
* `SD_DOS_200308.mif`
* `MAIN.asm.log.asz`

## ファイルの位置づけ
### `64KRAM.hex`
64KB RAM環境向けのEPROM用データ。`MANUAL.txt`には、HEXファイルの`6000H`から`7FFFH`までを使うと記載されている。

内容は`MAIN.asm`の出力そのものではなく、次の2部構成であることを確認した。

* `6000H`〜`604BH`: ローダ。60バイトのルーチンを高位RAM(`EDCEH`)へコピーして実行し、ポート`E2H`のバンク切り替えを使ってBASIC ROM(`0000H`〜`5FFFH`)を裏RAMへコピーし、続いて`604CH`にあるSD-DOS本体(長さ`BODY_LEN`。オリジナルは`18F0H`)を`6000H`へコピーしてから`6000H`へジャンプする
* `604CH`〜`793BH`: SD-DOS本体。リンクアドレスは`6000H`で、`MAIN.asm`のアセンブル出力とバイト一致することを確認した

このため、`MAIN.asm`の出力と`64KRAM.hex`の単純なバイナリ比較はできない。ローダ部分のソースは`LOADER64.asm`として復元済みで、`scripts/make64kram.py`による合成で`64KRAM.hex`をソースから再現できる(バイト一致を確認済み)。

### `SD_DOS_100119.wav`
32KB RAM + 8KB拡張RAM環境で、モニタからロードするためのWAV。`MANUAL.txt`に使用手順が記載されている。

### `SD_DOS_200308.wav`
WAV形式の成果物。更新履歴上は2020年3月8日版と対応している可能性が高いが、現時点では`MANUAL.txt`に直接の使用手順は確認できていない。

### `MAIN.cmt` / `IPL.cmt`
CMT形式の成果物。tools80 r6_50で`MAIN.asm`、`IPL.asm`をアセンブルした出力(MONITOR形式CMT)とバイト一致することを確認した。

### `SD_DOS_200308.mif`
Quartus Prime系のMemory Initialization File。`WIDTH=8`、`DEPTH=8192`であり、8KB ROM相当の初期化データと見られる。どの入力から作られたか、どのハードウェア構成で使うかは未確認。

### `MAIN.asm.log.asz`
`MAIN.asm`のアセンブルリストまたはログと見られる。公開対象として残すべきか、中間ファイルとして扱うべきかは未確認。

## 確認の進捗
1. `tools80.jar`の入手と実行 … 確認済み(r6_50、Homebrew OpenJDK)
2. `MAIN.cmt`、`IPL.cmt`の作成 … 確認済み(既存成果物とバイト一致)
3. `64KRAM.hex`との対応 … 確認済み(ローダソースを`LOADER64.asm`へ復元し、ソースからの再現でバイト一致)
4. CMTからWAVを作る方法 … 未確認
5. MIFの作成方法 … 未確認

ROMライタ、FPGA書き込み、実機ロードはビルドとは別作業として扱う。

## ディレクトリ構成
確認済みのビルド手順に基づき、次の構成に整理した。

* `src/`: アセンブリソース(`INCLUDE`はソースのあるディレクトリ基準で解決される)
* `docs/`: ビルド手順(この文書)
* `docs/design/`: 調査と設計の文書
* `scripts/`: ビルド補助スクリプト
* `tools/`: 手元に配置する外部ツール(ツール本体はgit管理外)
* `build/`: ビルド生成物(git管理外)
* `dist/original/`: オリジナルリポジトリ由来の成果物

確認済みの工程(CMT、64KRAM.hex)だけをMakefileのターゲットにしている。WAV、MIFは作成方法が確認できてから個別に検討する。

## 今後の確認事項
* CMTからWAVへの変換手順
* MIFの作成手順
