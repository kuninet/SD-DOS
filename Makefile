# PC-8001 SD-DOS ビルド用Makefile
#
# 前提:
#   - Java実行環境 (JAVA変数で指定可能)
#   - tools/tools80.jar (入手方法は tools/README.md を参照)
#
# 主なターゲット:
#   make          MAIN.cmt, IPL.cmt, 64KRAM.hex を build/ に生成する
#   make test     回帰テスト(複数クラスタ読みとストリーム読み出しAPI)を実行する
#   make list     アセンブルリストとシンボルファイルを build/ に生成する
#   make verify-orig  オリジナル成果物とのバイト一致確認(複数クラスタ読み修正前のコード専用)
#   make rom      EPROM書き込み用ROMイメージを build/rom/ に生成する
#   make burn     miniproでEPROMへ書き込む(例: make burn DEVICE=W27C512)
#   make clean    build/ を削除する

JAVA    ?= java
TOOLS80 ?= tools/tools80.jar
PYTHON  ?= python3
BUILD    = build

ASM = printf 'OK\n' | $(JAVA) -jar $(TOOLS80) -tgt=z80

ASM_SRCS = $(wildcard src/*.asm)

all: $(BUILD)/MAIN.cmt $(BUILD)/IPL.cmt $(BUILD)/64KRAM.hex $(BUILD)/SDUMP.cmt

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

$(BUILD)/SDUMP.cmt: samples/SDUMP.asm | $(BUILD)
	$(ASM) samples/SDUMP.asm
	mv samples/SDUMP.cmt $@

$(BUILD)/SDUMP.raw: samples/SDUMP.asm | $(BUILD)
	$(ASM) -raw samples/SDUMP.asm
	mv samples/SDUMP.raw $@

# -debugでアセンブルリスト(.log.asz)とシンボル(.sym)、-rawでベタイメージも生成する
$(BUILD)/MAIN.raw: $(ASM_SRCS) | $(BUILD)
	$(ASM) -raw -debug -sym src/MAIN.asm
	mv src/MAIN.raw $@
	mv src/MAIN.sym $(BUILD)/MAIN.sym
	mv src/MAIN.asm.log.asz $(BUILD)/MAIN.asm.log.asz

list: $(BUILD)/MAIN.raw

test: $(BUILD)/MAIN.raw $(BUILD)/SDUMP.raw
	$(PYTHON) scripts/test_emu_io.py
	$(PYTHON) scripts/test_multicluster.py $(BUILD)/MAIN.raw $(BUILD)/MAIN.sym
	$(PYTHON) scripts/test_stream_api.py $(BUILD)/MAIN.raw $(BUILD)/MAIN.sym
	$(PYTHON) scripts/test_sample.py $(BUILD)/MAIN.raw $(BUILD)/MAIN.sym $(BUILD)/SDUMP.raw

# EPROM書き込み用ROMイメージの一括生成
ROMDIR       = $(BUILD)/rom
ROM_DEVICES ?= 27C64 28C64 27C256 28C256 W27C512

rom: $(BUILD)/64KRAM.hex scripts/makerom.py
	mkdir -p $(ROMDIR)
	for d in $(ROM_DEVICES); do \
		$(PYTHON) scripts/makerom.py $(BUILD)/64KRAM.hex --device $$d -o $(ROMDIR)/64KRAM-$$d || exit 1; \
	done

# miniproによるEPROM書き込み。デバイス名は `minipro -L <検索語>` で確認すること
MINIPRO ?= minipro
DEVICE  ?= W27C512
ROM     ?= $(ROMDIR)/64KRAM-$(DEVICE).bin

burn:
	$(MINIPRO) -p "$(DEVICE)" -w "$(ROM)"

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

.PHONY: all verify-orig list test rom burn clean
