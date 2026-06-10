# PC-8001 SD-DOS ビルド用Makefile
#
# 前提:
#   - Java実行環境 (JAVA変数で指定可能)
#   - tools/tools80.jar (入手方法は tools/README.md を参照)
#
# 主なターゲット:
#   make          MAIN.cmt, IPL.cmt, 64KRAM.hex を build/ に生成する
#   make verify   生成物が dist/original/ のオリジナル成果物とバイト一致するか確認する
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

verify: all
	cmp $(BUILD)/MAIN.cmt dist/original/MAIN.cmt
	cmp $(BUILD)/IPL.cmt dist/original/IPL.cmt
	cmp $(BUILD)/64KRAM.hex dist/original/64KRAM.hex
	@echo "verify: OK (オリジナル成果物とバイト一致)"

$(BUILD):
	mkdir -p $(BUILD)

clean:
	rm -rf $(BUILD)

.PHONY: all verify clean
