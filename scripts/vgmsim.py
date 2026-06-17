#!/usr/bin/env python3
"""VGMプレイヤ cycle-accurate シミュレータ(Issue #68 / VGMIRQ F-1 の机上検証)。

z80mini の cycle 計測機能を使い、実機の SD-DOS 本体 + ストリーム読み出し API +
VGM プレイヤを実コードのまま動かして「再生に要する時間」を見積もる。

設計方針:
  ・SD のビットバンギング(MMC_1RD/MMC_BRD_CMD/MMC_BRD_END)は z80mini では
    SPI ポートを再現していないためフックで肩代わりするが、そのフックに実機実測の
    T-states を注入する。これにより STRM_READ / STRM_ADVANCE / FAT たどり等の
    ブックキーピングは実コードのまま cycle 計測され、走らせられないビットバンギング
    ループの時間だけを計測値で埋める。
  ・PC-8001 の実質クロックは CRTC DMA で 2MHz 相当(1 cycle = 0.5μs)。
    実時間 = cpu.cycles * 0.5μs。

得られる指標:
  ・VGM 理論再生時間(wait サンプル総和)vs シミュレータ経過時間 = テンポ比
  ・OPN/PSG 書込みのタイムライン
  ・リングバッファ残量の推移(wait ごと)
  ・SD 読み出し回数とその総コスト

使い方:
    make list  でシンボル(VGMPLAY.sym 等)を生成してから
    python3 scripts/vgmsim.py build/MAIN.raw build/MAIN.sym \\
            build/VGMPLAY.raw build/VGMPLAY.sym

次の着手(別セッション): samples/VGMIRQF.asm(F-1)実装 → 本シミュレータに Timer A /
割り込みモデルを足して検証(z80mini への IRQ ディスパッチ追加が必要)。
"""
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from test_multicluster import load_symbols
from test_stream_api import setup, make_disk, make_dent, START_CLSTR
from vgmfixture import make_vgm, ym2203, psg, wait, END
from z80mini import Trap

# ---- 時間換算(@2MHz 相当)----
CYCLE_US = 0.5                  # Z80 1 cycle = 0.5μs(PC-8001 実質 2MHz)
SAMPLE_US = 1_000_000 / 44100   # VGM 1 sample ≒ 22.6757μs(44100Hz)

# ---- 実機実測の SD ビットバンギング T-states(vgm-irq-session-handoff 参照)----
MMC_1RD_T = 678        # 1byte SPI 受信(MMC_1RD 最適化後)
MMC_BRD_CMD_T = 5000   # ブロック READ コマンド発行(セクタ開始)
MMC_BRD_END_T = 2 * MMC_1RD_T  # ブロック終端 = MMC_1RD 2回(CRC 読み)
HOOK_RET_T = 10        # setup() のフックは RET 相当で 10T 計上済み

PLAYER_ORG = 0x9000
BASIC = 0x0081
KEYWAIT = 0x0F75
IVR_FMTAV = 0x9003  # VGMIRQ/VGMIRQF 共通: FM Timer A IRQ ベクタ番号の POKE 点

# YM2203 Timer A: 1 tick = 72/master_clock。master=3.579545MHz、@2MHz 換算。
TA_TICK_CYCLES = (72.0 / 3_579_545) / (CYCLE_US * 1e-6)  # ≒ 40.23 cycles/tick


class TimerA:
    """YM2203 Timer A の最小モデル(周期 overflow + IRQ + ステータス flag)。

    レジスタは OUT 80H(アドレス)→OUT 81H(データ)の 2 段書きで届くため、
    呼び出し側が reg/val を解決して write() を呼ぶ。27H のビット配置:
      bit0=LoadA(計数開始) bit2=IRQEN A bit4=ResetA(flag クリア)
    """

    def __init__(self):
        self.reg24 = self.reg25 = 0
        self.running = False
        self.irqen = False
        self.flag = False          # overflow flag(ResetA まで保持)
        self.na = 0
        self.period = 0.0          # overflow 周期(cycles)
        self.next_ovf = 0.0
        self.overflows = 0

    def write(self, reg, val, cycles):
        if reg == 0x24:
            self.reg24 = val & 0xFF
        elif reg == 0x25:
            self.reg25 = val & 0x03
        elif reg == 0x27:
            load = bool(val & 0x01)
            self.irqen = bool(val & 0x04)
            if val & 0x10:                 # ResetA: overflow flag をクリア
                self.flag = False
            if load and not self.running:  # LoadA 0->1: NA ロードして計数開始
                self.na = (self.reg24 << 2) | (self.reg25 & 3)
                self.period = max(1.0, (1024 - self.na) * TA_TICK_CYCLES)
                self.next_ovf = cycles + self.period
                self.running = True
            elif not load:
                self.running = False

    def poll(self, cycles):
        """時間経過に合わせて overflow を反映する(自動リロードで周期動作)。"""
        if self.running and self.period > 0:
            while cycles >= self.next_ovf:
                self.flag = True
                self.overflows += 1
                self.next_ovf += self.period

    def status(self):
        return 0x01 if self.flag else 0x00  # bit0=Timer A flag, bit7(BUSY)=0


def make_sim(raw_path, syms, disk):
    """test_stream_api.setup() を土台に、MMC フックへ実測サイクルを注入する。

    setup() のフックは即時に値を返す(ビットバンギングを実行しない)ため、
    そのままでは SD 読みが 10T になってしまう。実機の T-states との差分を
    注入して、STRM 経路全体を cycle accurate にする。
    """
    cpu = setup(raw_path, syms, disk)
    for name, total_t in (("MMC_1RD", MMC_1RD_T),
                          ("MMC_BRD_CMD", MMC_BRD_CMD_T),
                          ("MMC_BRD_END", MMC_BRD_END_T)):
        orig = cpu.hooks[syms[name]]
        inject = total_t - HOOK_RET_T  # RET 相当の 10T は step() 側で加算される
        def wrapped(c, orig=orig, inject=inject):
            c.cycles += inject
            return orig(c)
        cpu.hooks[syms[name]] = wrapped
    return cpu


def vgm_total_samples(commands):
    """コマンド列の wait サンプル総和(VGM 理論再生時間の基)を求める。

    vgmfixture が生成しうる wait(61H/62H/63H/7nH)のみ解釈する。
    OPN(55H)/PSG(0A0H)書込みやデータブロックは時間を持たない。
    """
    i, total = 0, 0
    n = len(commands)
    while i < n:
        op = commands[i]
        if op == 0x66:           # end
            break
        elif op == 0x61:         # wait nnnn
            total += commands[i + 1] | (commands[i + 2] << 8)
            i += 3
        elif op == 0x62:         # wait 1/60
            total += 735
            i += 1
        elif op == 0x63:         # wait 1/50
            total += 882
            i += 1
        elif 0x70 <= op <= 0x7F:  # wait (n+1)
            total += (op & 0x0F) + 1
            i += 1
        elif op == 0x55:         # YM2203: reg, val
            i += 3
        elif op == 0xA0:         # PSG: reg, val
            i += 3
        else:
            # 本シミュレータのテストデータには現れない想定。安全側で1バイト進める
            i += 1
    return total


def run(raw_path, syms, psyms, player_raw, commands, keys="1\r",
        sample_every_wait=True, pokes=None):
    """プレイヤを実行し、再生区間の cycle/イベントを収集して dict で返す。

    pokes: {アドレス: 値} のマップ(実機 POKE 相当。例 {0x9003: 1} で WAIT_KV=1)。
    """
    vgm = make_vgm(commands)
    dents = [make_dent("MUSIC   VGM", START_CLSTR, len(vgm))]
    # クラスタ鎖をファイルサイズに合わせて伸ばす(1クラスタ=1024B)
    ncls = max(1, (len(vgm) + 1023) // 1024)
    chain = {}
    for k in range(ncls):
        c = START_CLSTR + k
        chain[c] = 0xFFFF if k == ncls - 1 else c + 1
    disk = make_disk(chain, vgm, dents)

    cpu = make_sim(raw_path, syms, disk)
    player = open(player_raw, "rb").read()
    cpu.mem[PLAYER_ORG:PLAYER_ORG + len(player)] = player
    for adr, val in (pokes or {}).items():       # 実機 POKE 相当(WAIT_KV 等)
        cpu.mem[adr] = val & 0xFF
    cpu.io_in[0x80] = lambda c: 0x00  # YM2203 ステータス: BUSY なし

    feed = list(keys.encode("ascii"))

    def keywait(c):
        c.a = feed.pop(0) if feed else 0x0D  # 尽きたら Enter→0→終了
        return True

    cpu.hooks[KEYWAIT] = keywait
    cpu.hooks[BASIC] = lambda c: (_ for _ in ()).throw(Trap("BASIC_EXIT", c))

    # ---- 計測用の状態 ----
    st = {"play_start": None, "play_end": None, "reads_at_play": 0,
          "sd_reads": 0, "sd_cost": 0, "waits": [], "opn": []}

    RB_CNT = psyms["RB_CNT"]
    WDEBT = psyms["WDEBT"]

    def rb_cnt():
        return cpu.mem[RB_CNT] | (cpu.mem[RB_CNT + 1] << 8)

    def wdebt():
        return cpu.mem[WDEBT] | (cpu.mem[WDEBT + 1] << 8)

    # 再生区間の開始/終了スタンプ(観測フックは None を返して実コードを続行させる)
    def on_play(c):
        if st["play_start"] is None:
            st["play_start"] = c.cycles
            st["reads_at_play"] = st["sd_reads"]  # 再生開始時点の累積読み数
        return None

    def on_done(c):
        if st["play_end"] is None:
            st["play_end"] = c.cycles
        return None

    cpu.hooks[psyms["PLAY"]] = on_play
    cpu.hooks[psyms["DONE"]] = on_done

    # SD 1byte 読み回数/コストを数える。MMC_1RD は make_sim が cycle 注入付きで
    # ラップ済みなので、その前段に計数を挟む(実体フックはそのまま呼ぶ)。
    wrapped_1rd = cpu.hooks[syms["MMC_1RD"]]

    def count_and_run(c, inner=wrapped_1rd):
        st["sd_reads"] += 1
        st["sd_cost"] += MMC_1RD_T
        return inner(c)

    cpu.hooks[syms["MMC_1RD"]] = count_and_run

    # wait ごとに残量等をサンプル(WAIT_DE 入口を観測)
    if sample_every_wait:
        WAIT_DE = psyms["WAIT_DE"]

        def on_wait(c):
            st["waits"].append({
                "cycles": c.cycles,
                "req": c.get_de(),       # 要求サンプル数
                "buf": rb_cnt(),         # リングバッファ残量
                "debt": wdebt(),         # 書込みコスト debt
                "reads": st["sd_reads"],
            })
            return None

        cpu.hooks[WAIT_DE] = on_wait

    # OPN/PSG 書込みをタイムスタンプ付きで記録
    def on_opn(c, v, port):
        st["opn"].append((c.cycles, port, v))

    for p in (0x80, 0x81, 0xA0, 0xA1):
        cpu.io_out_hooks[p] = lambda c, v, p=p: on_opn(c, v, p)

    try:
        cpu.call(PLAYER_ORG)
    except Trap as t:
        if "BASIC_EXIT" not in t.name:
            raise

    if st["play_end"] is None:
        st["play_end"] = cpu.cycles
    st["out"] = cpu.output.decode("ascii", "replace")
    st["total_cycles"] = cpu.cycles
    return st


def report(name, commands, st):
    samples = vgm_total_samples(commands)
    theo_us = samples * SAMPLE_US
    play_cyc = (st["play_end"] or 0) - (st["play_start"] or 0)
    sim_us = play_cyc * CYCLE_US
    tempo = (sim_us / theo_us) if theo_us else float("nan")

    print(f"=== {name}")
    print(f"  VGM 理論再生時間 : {theo_us / 1000:9.2f} ms ({samples} samples)")
    print(f"  シミュレータ経過 : {sim_us / 1000:9.2f} ms ({play_cyc} cycles)")
    print(f"  テンポ比 sim/理論: {tempo:6.3f}  "
          f"({'遅い' if tempo > 1.02 else '速い' if tempo < 0.98 else 'ほぼ一致'})")
    print(f"  ポート書込み     : {len(st['opn'])} 回 (OUT 80/81/A0/A1 単位)")
    play_reads = st["sd_reads"] - st["reads_at_play"]
    print(f"  SD 1byte 読み    : {st['sd_reads']} 回 (うち再生中 {play_reads} 回, "
          f"計 {st['sd_cost'] * CYCLE_US / 1000:.2f} ms)")
    if st["waits"]:
        last = st["waits"][-1]
        bufmax = max(w["buf"] for w in st["waits"])
        bufmin = min(w["buf"] for w in st["waits"])
        print(f"  バッファ残量     : 最大 {bufmax} / 最小 {bufmin} / 末尾 {last['buf']} byte")
    end_state = ("正常終了(VGM END)" if "VGM END" in st["out"]
                 else st["out"].strip().replace("\r\n", " ")[:40])
    print(f"  終了状態         : {end_state}")
    return tempo


def run_irq(raw_path, syms, psyms, player_raw, commands, keys="1\r",
            pokes=None, max_steps=200_000_000):
    """割り込み駆動プレイヤ(VGMIRQ/VGMIRQF)を Timer A モデル付きで実行する。

    YM2203 のレジスタ書きは OUT 80H(アドレス)→OUT 81H(データ)で届くので、
    81H フックで reg を解決し、24/25/27H なら Timer A へ、その他は音源書込みとして
    記録する。Timer A の overflow を割り込み源(irq_poll)に接続して F-1 / HALT 方式
    どちらの ISR も実コードのまま走らせる。
    """
    vgm = make_vgm(commands)
    dents = [make_dent("MUSIC   VGM", START_CLSTR, len(vgm))]
    ncls = max(1, (len(vgm) + 1023) // 1024)
    chain = {START_CLSTR + k: (0xFFFF if k == ncls - 1 else START_CLSTR + k + 1)
             for k in range(ncls)}
    disk = make_disk(chain, vgm, dents)

    cpu = make_sim(raw_path, syms, disk)
    player = open(player_raw, "rb").read()
    cpu.mem[PLAYER_ORG:PLAYER_ORG + len(player)] = player
    for adr, val in (pokes or {}).items():
        cpu.mem[adr] = val & 0xFF

    timer = TimerA()
    vec_byte = cpu.mem[IVR_FMTAV]  # IM2 のデバイス供給バイト(=ベクタ番号)

    # ステータス(IN 80H): bit0=Timer A flag, bit7=BUSY=0。読み時も時刻を反映
    def status_in(c):
        timer.poll(c.cycles)
        return timer.status()

    cpu.io_in[0x80] = status_in

    # 割り込み源: Timer A overflow かつ IRQEN なら IM2 ベクタ番号を返す
    def irq_poll(c):
        timer.poll(c.cycles)
        return vec_byte if (timer.flag and timer.irqen) else None

    cpu.irq_poll = irq_poll

    st = {"play_start": None, "play_end": None, "reads_at_play": 0,
          "sd_reads": 0, "sd_cost": 0, "opn": [], "buf_min": None,
          "underrun": 0, "out": ""}
    RB_CNT = psyms["RB_CNT"]
    RB_EOF = psyms["RB_EOF"]

    def rb_cnt():
        return cpu.mem[RB_CNT] | (cpu.mem[RB_CNT + 1] << 8)

    # YM2203 レジスタ書きの解決(80H=アドレス, 81H=データ)
    sel = {"reg": 0}

    def on_addr(c, v):
        sel["reg"] = v

    def on_data(c, v):
        reg = sel["reg"]
        if reg in (0x24, 0x25, 0x27):
            timer.write(reg, v, c.cycles)
        else:
            st["opn"].append((c.cycles, 0x81, reg, v))  # 音源レジスタ書込み

    cpu.io_out_hooks[0x80] = on_addr
    cpu.io_out_hooks[0x81] = on_data
    for p in (0xA0, 0xA1):
        cpu.io_out_hooks[p] = lambda c, v, p=p: st["opn"].append((c.cycles, p, None, v))

    def on_play(c):
        if st["play_start"] is None:
            st["play_start"] = c.cycles
            st["reads_at_play"] = st["sd_reads"]
        return None

    def on_done(c):
        if st["play_end"] is None:
            st["play_end"] = c.cycles
        return None

    cpu.hooks[psyms["PLAY"]] = on_play
    cpu.hooks[psyms["DONE"]] = on_done

    wrapped_1rd = cpu.hooks[syms["MMC_1RD"]]

    def count_1rd(c, inner=wrapped_1rd):
        st["sd_reads"] += 1
        st["sd_cost"] += MMC_1RD_T
        # 再生中のバッファ最小残量(枯渇=underrun を検出)
        if st["play_start"] is not None:
            cnt = rb_cnt()
            if st["buf_min"] is None or cnt < st["buf_min"]:
                st["buf_min"] = cnt
        return inner(c)

    cpu.hooks[syms["MMC_1RD"]] = count_1rd

    feed = list(keys.encode("ascii"))

    def keywait(c):
        c.a = feed.pop(0) if feed else 0x0D
        return True

    cpu.hooks[KEYWAIT] = keywait
    cpu.hooks[BASIC] = lambda c: (_ for _ in ()).throw(Trap("BASIC_EXIT", c))

    try:
        cpu.call(PLAYER_ORG, max_steps=max_steps)
    except Trap as t:
        if "BASIC_EXIT" not in t.name:
            st["out"] = cpu.output.decode("ascii", "replace")
            st["error"] = t.name
            st["timer"] = timer
            if st["play_end"] is None:
                st["play_end"] = cpu.cycles
            st["total_cycles"] = cpu.cycles
            return st

    if st["play_end"] is None:
        st["play_end"] = cpu.cycles
    st["out"] = cpu.output.decode("ascii", "replace")
    st["total_cycles"] = cpu.cycles
    st["timer"] = timer
    return st


def report_irq(name, commands, st):
    samples = vgm_total_samples(commands)
    theo_us = samples * SAMPLE_US
    play_cyc = (st["play_end"] or 0) - (st["play_start"] or 0)
    sim_us = play_cyc * CYCLE_US
    tempo = (sim_us / theo_us) if theo_us else float("nan")
    timer = st.get("timer")

    print(f"=== {name}")
    print(f"  VGM 理論再生時間 : {theo_us / 1000:9.2f} ms ({samples} samples)")
    print(f"  シミュレータ経過 : {sim_us / 1000:9.2f} ms ({play_cyc} cycles)")
    print(f"  テンポ比 sim/理論: {tempo:6.3f}  "
          f"({'遅い' if tempo > 1.02 else '速い' if tempo < 0.98 else 'ほぼ一致'})")
    if timer is not None:
        print(f"  Timer A overflow : {timer.overflows} 回 (IRQ 発火)")
    play_reads = st["sd_reads"] - st["reads_at_play"]
    print(f"  SD 1byte 読み    : {st['sd_reads']} 回 (うち再生中 {play_reads} 回)")
    print(f"  音源レジスタ書込 : {len(st['opn'])} 回")
    bm = st["buf_min"]
    print(f"  再生中バッファ最小: {bm if bm is not None else '—'} byte"
          + ("  ★枯渇(underrun)" if bm == 0 else ""))
    if "error" in st:
        print(f"  ❌ 異常停止       : {st['error']}")
    end_state = ("正常終了(VGM END)" if "VGM END" in st["out"]
                 else st["out"].strip().replace("\r\n", " ")[:50] or "(出力なし)")
    print(f"  終了状態         : {end_state}")
    return tempo


def main():
    if len(sys.argv) < 5:
        print("usage: vgmsim.py MAIN.raw MAIN.sym VGMPLAY.raw VGMPLAY.sym",
              file=sys.stderr)
        sys.exit(2)
    raw_path, sym_path, player_raw, psym_path = sys.argv[1:5]
    syms = load_symbols(sym_path)
    psyms = load_symbols(psym_path)

    print("VGM プレイヤ cycle-accurate シミュレータ (Issue #68)")
    print(f"  1 cycle = {CYCLE_US}μs (2MHz) / 1 sample = {SAMPLE_US:.4f}μs")
    print(f"  SD 実測: MMC_1RD={MMC_1RD_T}T BRD_CMD={MMC_BRD_CMD_T}T")
    print()

    # --- ケース1: 純 wait(SD 読みは起動時プレフィルで完結)。busy-loop テンポを測る ---
    cmd1 = wait(735) * 10 + END
    st1 = run(raw_path, syms, psyms, player_raw, cmd1)
    report("ケース1: wait 735 × 10(純 wait、SD 律速なし)", cmd1, st1)
    print()

    # --- ケース2: OPN 書込み + wait の現実的トラック。INITFILL を超えて SD 読みを誘発 ---
    frame = (b"".join(ym2203(0x30 + (k & 0x0F), (k * 7) & 0xFF) for k in range(12))
             + wait(735))
    FRAMES = 300
    cmd2 = frame * FRAMES + END
    st2 = run(raw_path, syms, psyms, player_raw, cmd2)
    report(f"ケース2: (OPN×12 + wait735) × {FRAMES}(再生中 SD 読みあり)", cmd2, st2)
    print()

    # --- WAIT_KV(9003H)スイープ: busy-loop テンポの調整点を探す ---
    #     SD 律速のない純 wait で測ると WAIT_KV に対してテンポがほぼ線形に動く。
    #     テンポ 1.0(実時間一致)に最も近い WAIT_KV が実機の推奨初期値。
    WAIT_KV_ADR = 0x9003
    print("=== WAIT_KV スイープ(純 wait・SD 律速なし。テンポ 1.0 = 実時間一致)")
    print("  WAIT_KV |  テンポ比 | 1サンプルあたり")
    best = None
    for kv in (0, 1, 2, 3, 4):
        s = run(raw_path, syms, psyms, player_raw, cmd1, pokes={WAIT_KV_ADR: kv})
        pc = (s["play_end"] or 0) - (s["play_start"] or 0)
        us = pc * CYCLE_US
        tempo = us / (vgm_total_samples(cmd1) * SAMPLE_US)
        per = us / vgm_total_samples(cmd1)
        mark = ""
        if best is None or abs(tempo - 1.0) < abs(best[1] - 1.0):
            best = (kv, tempo)
        print(f"    {kv:3d}   |  {tempo:6.3f}  | {per:6.2f}μs")
    print(f"  → テンポ 1.0 に最も近いのは WAIT_KV={best[0]} (比 {best[1]:.3f})")
    print()

    # --- 妥当性チェック(回帰用の軽い assert) ---
    ok = []
    ok.append(("ケース1が VGM END で終了", "VGM END" in st1["out"]))
    ok.append(("ケース2が VGM END で終了", "VGM END" in st2["out"]))
    ok.append(("ケース2で再生中 SD 読みが発生",
               st2["sd_reads"] - st2["reads_at_play"] > 0))
    # YM2203 書込み 1 回 = OUT 80H(reg)+OUT 81H(data) の 2 ポート書込み
    ok.append(("ポート書込み数が一致(12×2×300)", len(st2["opn"]) == 12 * 2 * FRAMES))
    # --- 割り込み駆動プレイヤの検証(IRQ.raw IRQ.sym が渡されたとき)---
    if len(sys.argv) >= 7:
        irq_raw, irq_sym = sys.argv[5], sys.argv[6]
        ipsyms = load_symbols(irq_sym)
        print("=== 割り込み機構の検証(既存 VGMIRQ.asm = HALT + IM2 を実行)")
        # 短いトラックで Timer A IRQ 経路を確認(wait 735 × 8 + end)
        cmdq = wait(735) * 8 + END
        sq = run_irq(raw_path, syms, ipsyms, irq_raw, cmdq)
        report_irq("VGMIRQ: wait 735 × 8(HALT 方式)", cmdq, sq)
        print()
        ok.append(("VGMIRQ が VGM END で終了", "VGM END" in sq["out"]))
        ok.append(("Timer A IRQ が発火した",
                   sq.get("timer") is not None and sq["timer"].overflows > 0))
        ok.append(("VGMIRQ で異常停止していない", "error" not in sq))

    print("=== 妥当性チェック")
    allok = True
    for label, cond in ok:
        print(f"  {'PASS' if cond else 'FAIL'}: {label}")
        allok = allok and cond
    sys.exit(0 if allok else 1)


if __name__ == "__main__":
    main()
