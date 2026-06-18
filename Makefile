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

all: $(BUILD)/MAIN.cmt $(BUILD)/IPL.cmt $(BUILD)/64KRAM.hex $(BUILD)/SDUMP.cmt $(BUILD)/VGMPLAY.cmt $(BUILD)/VGMIRQ.cmt $(BUILD)/VGMIRQP.cmt $(BUILD)/VGMIRQF.cmt $(BUILD)/VGMIRQS.cmt

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

$(BUILD)/VGMPLAY.cmt: samples/VGMPLAY.asm | $(BUILD)
	$(ASM) samples/VGMPLAY.asm
	mv samples/VGMPLAY.cmt $@

$(BUILD)/VGMPLAY.raw: samples/VGMPLAY.asm | $(BUILD)
	$(ASM) -raw samples/VGMPLAY.asm
	mv samples/VGMPLAY.raw $@

$(BUILD)/VGMIRQ.cmt: samples/VGMIRQ.asm | $(BUILD)
	$(ASM) samples/VGMIRQ.asm
	mv samples/VGMIRQ.cmt $@

$(BUILD)/VGMIRQ.raw: samples/VGMIRQ.asm | $(BUILD)
	$(ASM) -raw samples/VGMIRQ.asm
	mv samples/VGMIRQ.raw $@

$(BUILD)/VGMIRQ.asm.log.asz: samples/VGMIRQ.asm | $(BUILD)
	$(ASM) -raw -debug -sym samples/VGMIRQ.asm
	mv samples/VGMIRQ.asm.log.asz $@
	mv samples/VGMIRQ.sym $(BUILD)/VGMIRQ.sym
	rm -f samples/VGMIRQ.raw

$(BUILD)/VGMIRQF.cmt: samples/VGMIRQF.asm | $(BUILD)
	$(ASM) samples/VGMIRQF.asm
	mv samples/VGMIRQF.cmt $@

$(BUILD)/VGMIRQF.raw: samples/VGMIRQF.asm | $(BUILD)
	$(ASM) -raw samples/VGMIRQF.asm
	mv samples/VGMIRQF.raw $@

$(BUILD)/VGMIRQF.asm.log.asz: samples/VGMIRQF.asm | $(BUILD)
	$(ASM) -raw -debug -sym samples/VGMIRQF.asm
	mv samples/VGMIRQF.asm.log.asz $@
	mv samples/VGMIRQF.sym $(BUILD)/VGMIRQF.sym
	rm -f samples/VGMIRQF.raw

$(BUILD)/INTTEST.cmt: samples/INTTEST.asm | $(BUILD)
	$(ASM) samples/INTTEST.asm
	mv samples/INTTEST.cmt $@

$(BUILD)/VGMIRQS.cmt: samples/VGMIRQS.asm | $(BUILD)
	$(ASM) samples/VGMIRQS.asm
	mv samples/VGMIRQS.cmt $@

$(BUILD)/VGMIRQS.raw: samples/VGMIRQS.asm | $(BUILD)
	$(ASM) -raw samples/VGMIRQS.asm
	mv samples/VGMIRQS.raw $@

$(BUILD)/VGMIRQS.asm.log.asz: samples/VGMIRQS.asm | $(BUILD)
	$(ASM) -raw -debug -sym samples/VGMIRQS.asm
	mv samples/VGMIRQS.asm.log.asz $@
	mv samples/VGMIRQS.sym $(BUILD)/VGMIRQS.sym
	rm -f samples/VGMIRQS.raw

$(BUILD)/VGMIRQP.cmt: samples/VGMIRQP.asm | $(BUILD)
	$(ASM) samples/VGMIRQP.asm
	mv samples/VGMIRQP.cmt $@

$(BUILD)/VGMIRQP.raw: samples/VGMIRQP.asm | $(BUILD)
	$(ASM) -raw samples/VGMIRQP.asm
	mv samples/VGMIRQP.raw $@

$(BUILD)/VGMIRQP.asm.log.asz: samples/VGMIRQP.asm | $(BUILD)
	$(ASM) -raw -debug -sym samples/VGMIRQP.asm
	mv samples/VGMIRQP.asm.log.asz $@
	mv samples/VGMIRQP.sym $(BUILD)/VGMIRQP.sym
	rm -f samples/VGMIRQP.raw

$(BUILD)/TATEST.cmt: samples/TATEST.asm | $(BUILD)
	$(ASM) samples/TATEST.asm
	mv samples/TATEST.cmt $@

$(BUILD)/OPNCHK.cmt: samples/OPNCHK.asm | $(BUILD)
	$(ASM) samples/OPNCHK.asm
	mv samples/OPNCHK.cmt $@

$(BUILD)/TIMRSEE.cmt: samples/TIMRSEE.asm | $(BUILD)
	$(ASM) samples/TIMRSEE.asm
	mv samples/TIMRSEE.cmt $@

$(BUILD)/TATEST3.cmt: samples/TATEST3.asm | $(BUILD)
	$(ASM) samples/TATEST3.asm
	mv samples/TATEST3.cmt $@

$(BUILD)/POLL10.cmt: samples/POLL10.asm | $(BUILD)
	$(ASM) samples/POLL10.asm
	mv samples/POLL10.cmt $@

$(BUILD)/VGMIRQM.cmt: samples/VGMIRQM.asm | $(BUILD)
	$(ASM) samples/VGMIRQM.asm
	mv samples/VGMIRQM.cmt $@

# -debugでアセンブルリスト(.log.asz)とシンボル(.sym)、-rawでベタイメージも生成する
$(BUILD)/MAIN.raw: $(ASM_SRCS) | $(BUILD)
	$(ASM) -raw -debug -sym src/MAIN.asm
	mv src/MAIN.raw $@
	mv src/MAIN.sym $(BUILD)/MAIN.sym
	mv src/MAIN.asm.log.asz $(BUILD)/MAIN.asm.log.asz

# VGMPLAYのアセンブルリスト(.asm.log.asz)とシンボル(.sym)も -debug で生成する
$(BUILD)/VGMPLAY.asm.log.asz: samples/VGMPLAY.asm | $(BUILD)
	$(ASM) -raw -debug -sym samples/VGMPLAY.asm
	mv samples/VGMPLAY.asm.log.asz $@
	mv samples/VGMPLAY.sym $(BUILD)/VGMPLAY.sym
	rm -f samples/VGMPLAY.raw

list: $(BUILD)/MAIN.raw $(BUILD)/VGMPLAY.asm.log.asz $(BUILD)/VGMIRQ.asm.log.asz $(BUILD)/VGMIRQP.asm.log.asz

test: $(BUILD)/MAIN.raw $(BUILD)/SDUMP.raw $(BUILD)/VGMPLAY.raw
	$(PYTHON) scripts/test_emu_io.py
	$(PYTHON) scripts/test_multicluster.py $(BUILD)/MAIN.raw $(BUILD)/MAIN.sym
	$(PYTHON) scripts/test_stream_api.py $(BUILD)/MAIN.raw $(BUILD)/MAIN.sym
	$(PYTHON) scripts/test_sample.py $(BUILD)/MAIN.raw $(BUILD)/MAIN.sym $(BUILD)/SDUMP.raw
	$(PYTHON) scripts/test_vgmplay.py $(BUILD)/MAIN.raw $(BUILD)/MAIN.sym $(BUILD)/VGMPLAY.raw

# VGMプレイヤ cycle-accurate シミュレータ(Issue #68 / VGMIRQ F-1 机上検証)
# VGMPLAY.sym が必要なため list(=-debug アセンブル)に依存する
vgmsim: $(BUILD)/MAIN.raw $(BUILD)/VGMPLAY.raw $(BUILD)/VGMPLAY.asm.log.asz \
        $(BUILD)/VGMIRQ.raw $(BUILD)/VGMIRQ.asm.log.asz \
        $(BUILD)/VGMIRQF.raw $(BUILD)/VGMIRQF.asm.log.asz
	$(PYTHON) scripts/vgmsim.py $(BUILD)/MAIN.raw $(BUILD)/MAIN.sym \
		$(BUILD)/VGMPLAY.raw $(BUILD)/VGMPLAY.sym \
		$(BUILD)/VGMIRQ.raw $(BUILD)/VGMIRQ.sym \
		$(BUILD)/VGMIRQF.raw $(BUILD)/VGMIRQF.sym

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

.PHONY: all verify-orig list test vgmsim rom burn clean
