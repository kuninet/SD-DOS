# SD-DOS アーキテクチャ概要

## 目的

SD-DOS全体の構成と、ストリーム読み出しAPIの位置づけを俯瞰する。実装の進行に合わせて更新する前提の文書である。

## システム構成

対象は初代PC-8001である。拡張ポートに接続したmicroSDドライブ(8255によるビットバンギングでSDを制御)と拡張RAM(8KBバッテリバックアップRAMまたは64KB RAM)を使用する。

SD-DOS本体は6000H-7FFFHの空きROM領域に常駐する。8KB拡張RAM環境ではRAM化した同領域へロードし、64KB RAM環境ではEPROM(64KRAM.hex)から起動する。64KB RAM版は [ビルド手順](build.md) に詳細が記載されており、ローダ(src/LOADER64.asm)が起動時にBASIC ROMとSD-DOS本体を裏RAMへコピーしてからポートE2Hのバンク切り替えを行い、6000Hから起動する。

## 起動と常駐の仕組み

6000Hに置いた「AB」マーカーにより、N-BASICが起動時にSD-DOSの初期化ルーチンを自動実行する。

初期化(MAIN.asm)はFAT16ワーク初期化、DWORD用スタック初期化、コマンドフック書き換え(INIT_CMDHOOK)、ファンクションキー設定、BASICワーク初期化を行い、BASICへ戻る。

INIT_CMDHOOKは、N-BASICがRAM上に持つ拡張命令フックベクタ(0F0FDH〜0F154H付近)をSD-DOSのルーチンへ書き換える。これにより、MOUNT、FILES、LOAD、SAVE、KILL、NAME、MERGE、CMD、RBYTEがBASIC命令として利用できるようになる。

CMD命令はCMD_TABLE(コマンド語)とJUMP_TABLE(飛び先)によるサブコマンド方式で実装される。サブコマンドとしてCMD R、CMD P、CMD V、CMD ON/OFF、CMD Fなどが存在する。

## モジュール構成

```
BASIC命令(フック) / 機械語API(ジャンプテーブル)
        ↓
コマンド層(CMD/EXT) → ファイル形式層(CMT/BAS/BIN/RAW)
        ↓
ファイルシステム層(DIR/CD/FAT/FP/FS)
        ↓
バッファ層(BUFFER: FAT_BFFR/FILE_BFFR)
        ↓
デバイス層(MMC: 8255ビットバンギング)
```

### コマンド層

- CMD.asm: CMD系サブコマンドと各命令の本体
- EXT.asm: 拡張コマンド(CMD CP/D/EX/MD/S)。ORG 0C000Hの別配置ブロックで、INIT_EXT_CMDがJUMP_TABLEを書き換えて有効化する。MAIN.asmの出力に含まれるがEPROMイメージ(6000H-7FFFH)には含まれない

### ファイル形式層

- CMT.asm/BAS.asm/BIN.asm: 拡張子別の読み書き。EXT_LOAD_TABLEで分岐する。PREP_READ/PREP_WRITEなどの共通前処理もCMT.asmにある
- RAW.asm: RBYTE用の任意ファイル一括読み込み(READ_RAW)

### ファイルシステム層

- DIR.asm: ディレクトリエントリの検索・作成・更新(GET_DENTなど)
- CD.asm: ワーキングディレクトリの変更
- FAT.asm: FATエントリの読み書き(READ_FAT_DATAなど)
- FP.asm: ファイルポインタ。逐次読み(FETCH_1BYTE/INC_FP/NEXT_CLSTR)、書き込み(POST_1BYTE/INC_FP_W)、終端設定(SET_FP_END)
- FS.asm: クラスタ⇔セクタ変換、セクタ読み書き(READ_SCTR/WRITE_SCTR)

### バッファ層

- BUFFER.asm: 512バイトのバッファ2面(FAT用FAT_BFFR、ファイル・ディレクトリ兼用FILE_BFFR)と、セクタ#・アドレス・更新フラグを持つバッファ構造体の管理(LOAD_BFFR/SAVE_BFFR)

### デバイス層

- MMC.asm: 8255経由のビットバンギングによるSDメモリカード制御。タイムアウト時はエラー終了する

### 共通

- SUBS.asm(汎用処理とERR)、DWORD.asm(4バイト演算)、STR.asm(文字列)、TP.asm(BASICテキストポインタ)、DATE.asm(日時)、DUMP.asm(ダンプ表示)、MESSAGES.asm、ERROR.asm、LABELS.asm(定数)、N80.asm(N-BASIC ROMのアドレス定義)
- IPL.asm: 別ビルドのIPL(IPL.cmt)

## 読み出し経路

現在の読み出し経路は次のとおりである。

LOADはファイル名解決後、EXT_LOAD_TABLEで拡張子別処理へ分岐し、PREP_READ→FETCH_1BYTEの繰り返しで読む。RBYTEはREAD_RAWが同じ低レベル経路を使う。

セクタ・クラスタ境界はINC_FPが内部で処理し、LOAD_BFFR→READ_SCTR→MMCの順でSDから読む。

エラー(SDタイムアウト、FATリンク終端超過など)はERR/ERRORからN-BASICのエラー処理(03BF9H)へジャンプし、呼び出し側へ戻らない。

既知の問題として、複数クラスタにまたがるファイルは2クラスタ目以降が正しく読めない。原因と詳細は [複数クラスタ読みの既存挙動の確認結果](design/multicluster-read.md) を参照する。

## ストリーム読み出しAPIの位置づけ

任意ファイルを少しずつ読み出す汎用ストリームアクセス機能を実装している(src/STRM.asmとMAIN.asm先頭のジャンプテーブル)。利用例はVGM再生サンプル(別途作成)である。

呼び出し口は機械語APIとし、プログラム先頭の固定位置に置くジャンプテーブルで公開する(詳細は [ストリーム読み出しの呼び出し口](design/entry-point.md) を参照)。エントリ構成はオープン(6005H)、1バイト取得(6008H)、クローズ(600BH)と予約2エントリである。

読み出し基盤(FP/バッファ/FAT/FS/MMCの各層)を再利用するが、セクタ#の算出は既知の問題を避けるためカレントクラスタから直接行う([複数クラスタ読みの既存挙動の確認結果](design/multicluster-read.md) 参照)。

状態は既存FP系ワークに加え、残りバイト数(4バイト)、EOFフラグ、エラー状態、読み出し中フラグを持つ([ストリーム読み出しの状態管理](design/seq-read-state.md) 参照)。取得単位は1バイト、バッファは既存FILE_BFFRを再利用する([ストリーム読み出しの取得単位とバッファ](design/buffer-unit.md) 参照)。

EOFは取得前判定で正常終了として返す。エラーは初期実装では既存の非復帰経路のまま([ストリーム読み出しのEOF・エラー・長尺ファイルの扱い](design/eof-error.md) 参照)。シークは初期実装に含めない([ストリーム読み出しのシーク機能の要否](design/seek.md) 参照)。既存のLOAD/RBYTE/READ_RAWの動作は変えない([LOAD/RBYTE/RAWとストリーム読み出しの役割分担](design/load-rbyte-raw.md) 参照)。

## 既知の課題

### 複数クラスタ読みの不整合

複数クラスタにまたがるファイルで2クラスタ目以降の読み込みが正しくない問題があったが、修正済みである(`FP2SCTR`のカレントクラスタ直接化と`SET_FP_END`の規約合わせ)。詳細は [複数クラスタ読みの既存挙動の確認結果](design/multicluster-read.md) を参照する。

### クラスタ境界での終端エラー

INC_FPの境界先読みにより、クラスタ境界ちょうどで終わるファイルの最終バイト取得が非復帰エラーに到達する。

### FATウォークのカウンタ制限

GET_FP_CLSTRのループカウンタが8ビットのため、先頭から256クラスタ以上のFATウォークに使えない。

### 非復帰エラー経路

エラー経路が非復帰であり、呼び出し側へ状態を返せない。
