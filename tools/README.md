# tools/

ビルドに使う外部ツールを置くディレクトリ。ツール本体は再配布しないため、リポジトリには含めない(このREADME以外は.gitignore対象)。

## tools80.jar

* 入手元: OUT of STANDARD http://upd780c1.g1.xrea.com/pc-8001/index.html の `bin/tools80_r6_50.lzh`
* `.lzh`を展開し、`tools80.jar`をこのディレクトリに置く
* r6_50(Ver 6.6.68)で動作確認済み。r6_44以前は`SET`で始まるラベルがエラーになるため使わないこと
* Java実行環境が必要。macOSではHomebrewの`openjdk`で動作確認済み

詳細は [docs/build.md](../docs/build.md) を参照。
