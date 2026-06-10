# PC-8001 SD-DOS ビルド用Makefile
#
# 前提:
#   - Java実行環境 (JAVA変数で指定可能)
#   - tools/tools80.jar (入手方法は tools/README.md を参照)
#
# 主なターゲット:
#   make          MAIN.cmt, IPL.cmt, 64KRAM.hex を build/ に生成する
#   make test     回帰テスト(scripts/test_multicluster.py)を実行する
#   make list     アセンブルリストとシンボルファイルを build/ に生成する
#   make verify-orig  オリジナル成果物とのバイト一致確認(複数クラスタ読み修正前のコード専用)
#   make clean    build/ を削除する

JAVA    ?= java
TOOLS80 ?= tools/tools80.jar
PYTHON  ?= python3
BUILD    = build

ASM = printf 'OK\n' | $(JAVA) -jar $(TOOLS80) -tgt=z80

ASM_SRCS = $(wildcard src/*.asm)

all: $(BUILD)/MAIN.cmt $(BUILD)/IPL.cmt $(BUILD)/64KRAM.hex

$(BUILD)/MAIN.cmt: $(ASM_SRCS) | $(BUILD)
	$(ASM) src/MAIN.asm
	mv src/MAIN.cmt $@

$(BUILD)/IPL.cmt: src/IPL.asm | $(BUILD)
	$(ASM) src/IPL.asm
	mv src/IPL.cmt $@

$(BUILD)/MAIN.hex: $(ASM_SRCS) | $(BUILD)
	$(ASM) -hex src/MAIN.asm
	mv src/MAIN.hex $@

$(BUILD)/LOADER64.hex: src/LOADER64.asm | $(BUILD)
	$(ASM) -hex src/LOADER64.asm
	mv src/LOADER64.hex $@

$(BUILD)/64KRAM.hex: $(BUILD)/LOADER64.hex $(BUILD)/MAIN.hex scripts/make64kram.py
	$(PYTHON) scripts/make64kram.py $(BUILD)/LOADER64.hex $(BUILD)/MAIN.hex -o $@

# -debugでアセンブルリスト(.log.asz)とシンボル(.sym)、-rawでベタイメージも生成する
$(BUILD)/MAIN.raw: $(ASM_SRCS) | $(BUILD)
	$(ASM) -raw -debug -sym src/MAIN.asm
	mv src/MAIN.raw $@
	mv src/MAIN.sym $(BUILD)/MAIN.sym
	mv src/MAIN.asm.log.asz $(BUILD)/MAIN.asm.log.asz

list: $(BUILD)/MAIN.raw

test: $(BUILD)/MAIN.raw
	$(PYTHON) scripts/test_multicluster.py $(BUILD)/MAIN.raw $(BUILD)/MAIN.sym

# オリジナル再現の確認用。複数クラスタ読みのバグ修正以降のコードでは一致しない
verify-orig: all
	cmp $(BUILD)/MAIN.cmt dist/original/MAIN.cmt
	cmp $(BUILD)/IPL.cmt dist/original/IPL.cmt
	cmp $(BUILD)/64KRAM.hex dist/original/64KRAM.hex
	@echo "verify-orig: OK (オリジナル成果物とバイト一致)"

$(BUILD):
	mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD)

.PHONY: all verify-orig list test clean
