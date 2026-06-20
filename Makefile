# PC-8001 SD-DOS ビルド用Makefile
#
# 前提:
#   - Java実行環境 (JAVA変数で指定可能)
#   - tools/tools80.jar (入手方法は tools/README.md を参照)
#
# 主なターゲット:
#   make          MAIN/IPL/64KRAM + サンプル(SDUMP, VGMPLAY, VGMIRQS)を build/ に生成する
#   make experiments  参考: samples/experiments/ の実験・診断プログラムを build/ に生成する
#   make test     回帰テスト(複数クラスタ読みとストリーム読み出しAPI)を実行する
#   make list     アセンブルリストとシンボルファイルを build/ に生成する
#   make verify-orig  オリジナル成果物とのバイト一致確認(複数クラスタ読み修正前のコード専用)
#   make rom      EPROM書き込み用ROMイメージを build/rom/ に生成する
#   make burn     miniproでEPROMへ書き込む(規定値はW27C512@DIP28)
#   make clean    build/ を削除する

JAVA    ?= java
TOOLS80 ?= tools/tools80.jar
PYTHON  ?= python3
BUILD    = build

ASM = printf 'OK\n' | $(JAVA) -jar $(TOOLS80) -tgt=z80

ASM_SRCS = $(wildcard src/*.asm)

all: $(BUILD)/MAIN.cmt $(BUILD)/IPL.cmt $(BUILD)/64KRAM.hex $(BUILD)/SDUMP.cmt $(BUILD)/VGMPLAY.cmt $(BUILD)/SDRECV.cmt $(BUILD)/VGMIRQS.cmt

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

$(BUILD)/SDRECV.cmt: samples/SDRECV.asm | $(BUILD)
	$(ASM) samples/SDRECV.asm
	mv samples/SDRECV.cmt $@

$(BUILD)/SDRECV.raw: samples/SDRECV.asm | $(BUILD)
	$(ASM) -raw -debug -sym samples/SDRECV.asm
	mv samples/SDRECV.raw $@
	mv samples/SDRECV.sym $(BUILD)/SDRECV.sym
	rm -f samples/SDRECV.asm.log.asz

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

# ===== 参考: 実験・診断プログラム(samples/experiments/。詳細はそこの README) =====
EXP = samples/experiments

experiments: $(BUILD)/VGMIRQ.cmt $(BUILD)/VGMIRQP.cmt $(BUILD)/VGMIRQM.cmt \
             $(BUILD)/VGMIRQF.cmt $(BUILD)/INTTEST.cmt $(BUILD)/OPNCHK.cmt \
             $(BUILD)/POLL10.cmt $(BUILD)/TIMRSEE.cmt $(BUILD)/TATEST.cmt \
             $(BUILD)/TATEST3.cmt

# VGMIRQ / VGMIRQF は vgmsim の机上検証でも使うので raw / sym も生成する
$(BUILD)/VGMIRQ.cmt: $(EXP)/VGMIRQ.asm | $(BUILD)
	$(ASM) $(EXP)/VGMIRQ.asm
	mv $(EXP)/VGMIRQ.cmt $@

$(BUILD)/VGMIRQ.raw: $(EXP)/VGMIRQ.asm | $(BUILD)
	$(ASM) -raw $(EXP)/VGMIRQ.asm
	mv $(EXP)/VGMIRQ.raw $@

$(BUILD)/VGMIRQ.asm.log.asz: $(EXP)/VGMIRQ.asm | $(BUILD)
	$(ASM) -raw -debug -sym $(EXP)/VGMIRQ.asm
	mv $(EXP)/VGMIRQ.asm.log.asz $@
	mv $(EXP)/VGMIRQ.sym $(BUILD)/VGMIRQ.sym
	rm -f $(EXP)/VGMIRQ.raw

$(BUILD)/VGMIRQF.cmt: $(EXP)/VGMIRQF.asm | $(BUILD)
	$(ASM) $(EXP)/VGMIRQF.asm
	mv $(EXP)/VGMIRQF.cmt $@

$(BUILD)/VGMIRQF.raw: $(EXP)/VGMIRQF.asm | $(BUILD)
	$(ASM) -raw $(EXP)/VGMIRQF.asm
	mv $(EXP)/VGMIRQF.raw $@

$(BUILD)/VGMIRQF.asm.log.asz: $(EXP)/VGMIRQF.asm | $(BUILD)
	$(ASM) -raw -debug -sym $(EXP)/VGMIRQF.asm
	mv $(EXP)/VGMIRQF.asm.log.asz $@
	mv $(EXP)/VGMIRQF.sym $(BUILD)/VGMIRQF.sym
	rm -f $(EXP)/VGMIRQF.raw

$(BUILD)/VGMIRQP.cmt: $(EXP)/VGMIRQP.asm | $(BUILD)
	$(ASM) $(EXP)/VGMIRQP.asm
	mv $(EXP)/VGMIRQP.cmt $@

$(BUILD)/VGMIRQM.cmt: $(EXP)/VGMIRQM.asm | $(BUILD)
	$(ASM) $(EXP)/VGMIRQM.asm
	mv $(EXP)/VGMIRQM.cmt $@

$(BUILD)/INTTEST.cmt: $(EXP)/INTTEST.asm | $(BUILD)
	$(ASM) $(EXP)/INTTEST.asm
	mv $(EXP)/INTTEST.cmt $@

$(BUILD)/OPNCHK.cmt: $(EXP)/OPNCHK.asm | $(BUILD)
	$(ASM) $(EXP)/OPNCHK.asm
	mv $(EXP)/OPNCHK.cmt $@

$(BUILD)/POLL10.cmt: $(EXP)/POLL10.asm | $(BUILD)
	$(ASM) $(EXP)/POLL10.asm
	mv $(EXP)/POLL10.cmt $@

$(BUILD)/TIMRSEE.cmt: $(EXP)/TIMRSEE.asm | $(BUILD)
	$(ASM) $(EXP)/TIMRSEE.asm
	mv $(EXP)/TIMRSEE.cmt $@

$(BUILD)/TATEST.cmt: $(EXP)/TATEST.asm | $(BUILD)
	$(ASM) $(EXP)/TATEST.asm
	mv $(EXP)/TATEST.cmt $@

$(BUILD)/TATEST3.cmt: $(EXP)/TATEST3.asm | $(BUILD)
	$(ASM) $(EXP)/TATEST3.asm
	mv $(EXP)/TATEST3.cmt $@

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

list: $(BUILD)/MAIN.raw $(BUILD)/VGMPLAY.asm.log.asz $(BUILD)/VGMIRQS.asm.log.asz

test: $(BUILD)/MAIN.raw $(BUILD)/SDUMP.raw $(BUILD)/VGMPLAY.raw $(BUILD)/SDRECV.raw
	$(PYTHON) scripts/test_emu_io.py
	$(PYTHON) scripts/test_multicluster.py $(BUILD)/MAIN.raw $(BUILD)/MAIN.sym
	$(PYTHON) scripts/test_stream_api.py $(BUILD)/MAIN.raw $(BUILD)/MAIN.sym
	$(PYTHON) scripts/test_sample.py $(BUILD)/MAIN.raw $(BUILD)/MAIN.sym $(BUILD)/SDUMP.raw
	$(PYTHON) scripts/test_vgmplay.py $(BUILD)/MAIN.raw $(BUILD)/MAIN.sym $(BUILD)/VGMPLAY.raw
	$(PYTHON) scripts/test_sdrecv.py $(BUILD)/SDRECV.raw $(BUILD)/SDRECV.sym

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

# miniproによるEPROM書き込み。
# DEVICE はminiproが要求するパッケージ付きの名前(例 W27C512@DIP28)。
# ROM_NAME はbuild/rom/64KRAM-<名前>.bin のサフィックス。@DIP28を外しておく。
# 別パッケージや別デバイスで焼くときは make burn DEVICE=... ROM_NAME=... で上書き。
# 検索: minipro -L <型番>
MINIPRO  ?= minipro
DEVICE   ?= W27C512@DIP28
ROM_NAME ?= W27C512
ROM      ?= $(ROMDIR)/64KRAM-$(ROM_NAME).bin

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

.PHONY: all experiments verify-orig list test vgmsim rom burn clean
