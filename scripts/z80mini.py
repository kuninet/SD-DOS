"""最小限のZ80インタプリタ。

SD-DOSの読み出し経路の検証(scripts/test_multicluster.py)に必要な範囲の
命令を実装している。未実装の命令に当たった場合は例外で停止する。
"""

S, Z, H, PV, N, C = 0x80, 0x40, 0x10, 0x04, 0x02, 0x01

# 命令ごとの基本 T-states テーブル(条件付きジャンプは not-taken 側、
# taken は分岐実行時に +5(JR cc, CALL cc) / +6(RET cc) / +5(DJNZ) を加算)
# CB/ED/DD/FD プレフィクスはここでは prefix 1 バイト分の 4T のみ計上し、
# sub オペコードの追加 T-states は分岐内で加算する
_BASE_T = [
    # 0x00 - 0x0F
    4, 10,  7,  6,  4,  4,  7,  4,  4, 11,  7,  6,  4,  4,  7,  4,
    # 0x10 - 0x1F  (DJNZ=8 not-taken, JR=12)
    8, 10,  7,  6,  4,  4,  7,  4, 12, 11,  7,  6,  4,  4,  7,  4,
    # 0x20 - 0x2F  (JR cc=7 not-taken)
    7, 10, 16,  6,  4,  4,  7,  4,  7, 11, 16,  6,  4,  4,  7,  4,
    # 0x30 - 0x3F
    7, 10, 13,  6, 11, 11, 10,  4,  7, 11, 13,  6,  4,  4,  7,  4,
    # 0x40 - 0x47 LD B,r
    4, 4, 4, 4, 4, 4, 7, 4,
    # 0x48 - 0x4F LD C,r
    4, 4, 4, 4, 4, 4, 7, 4,
    # 0x50 - 0x57 LD D,r
    4, 4, 4, 4, 4, 4, 7, 4,
    # 0x58 - 0x5F LD E,r
    4, 4, 4, 4, 4, 4, 7, 4,
    # 0x60 - 0x67 LD H,r
    4, 4, 4, 4, 4, 4, 7, 4,
    # 0x68 - 0x6F LD L,r
    4, 4, 4, 4, 4, 4, 7, 4,
    # 0x70 - 0x77 LD (HL),r (0x76=HALT)
    7, 7, 7, 7, 7, 7, 4, 7,
    # 0x78 - 0x7F LD A,r
    4, 4, 4, 4, 4, 4, 7, 4,
    # 0x80 - 0xBF ALU A,r (r=(HL) は 7、それ以外 4)
    4, 4, 4, 4, 4, 4, 7, 4,  4, 4, 4, 4, 4, 4, 7, 4,
    4, 4, 4, 4, 4, 4, 7, 4,  4, 4, 4, 4, 4, 4, 7, 4,
    4, 4, 4, 4, 4, 4, 7, 4,  4, 4, 4, 4, 4, 4, 7, 4,
    4, 4, 4, 4, 4, 4, 7, 4,  4, 4, 4, 4, 4, 4, 7, 4,
    # 0xC0 - 0xCF
    5, 10, 10, 10, 10, 11, 7, 11,   5, 10, 10, 4, 10, 17, 7, 11,
    # 0xD0 - 0xDF
    5, 10, 10, 11, 10, 11, 7, 11,   5, 4, 10, 11, 10, 4, 7, 11,
    # 0xE0 - 0xEF (EX (SP),HL=19, JP (HL)=4, ED prefix=4)
    5, 10, 10, 19, 10, 11, 7, 11,   5, 4, 10, 4, 10, 4, 7, 11,
    # 0xF0 - 0xFF (LD SP,HL=6, FD prefix=4)
    5, 10, 10, 4, 10, 11, 7, 11,   5, 6, 10, 4, 10, 4, 7, 11,
]


class Trap(Exception):
    """フックアドレスへ到達したことを表す"""

    def __init__(self, name, cpu):
        super().__init__(name)
        self.name = name
        self.cpu = cpu


class Z80:
    def __init__(self):
        self.mem = bytearray(0x10000)
        self.a = self.f = 0
        self.b = self.c = self.d = self.e = self.h = self.l = 0
        self.a2 = self.f2 = 0
        self.b2 = self.c2 = self.d2 = self.e2 = self.h2 = self.l2 = 0
        self.ix = self.iy = 0
        self.sp = 0xF000
        self.pc = 0
        self.hooks = {}  # アドレス -> callable(cpu)。Trueを返すとRET相当を行う
        self.rst_hooks = {}  # RSTベクタ(08H,10H,...) -> callable(cpu)
        self.output = bytearray()  # RSTフック等が捕捉した出力
        self.io_log = []  # OUT (n),A の記録 [(ポート, 値), ...]
        self.io_in = {}  # ポート -> callable(cpu)->値。未登録ポートのINは0FFH
        # ---- クロックサイクル積算 (cycle accurate 用) ----
        # step() 内で各命令の T-states を加算する。未対応の命令は概算 4T。
        # PC-8001 実質クロックは 2MHz 相当なので、実時間化は cycles * 0.5e-6 秒。
        self.cycles = 0
        # 命令フック (cycles で時間を進めるためのコールバック等を載せられる)
        self.io_out_hooks = {}  # ポート -> callable(cpu, value) (OUT 後の追加処理用)
        # ---- 割り込み (Timer A IRQ 等の検証用) ----
        # irq_poll が None の間は割り込み機構は完全に無効で、HALT は従来どおり
        # Trap を送出する(既存テストとの互換)。irq_poll を設定すると HALT は
        # INT 待ちになり、step() 入口で irq_poll が返したベクタで割り込みを受理する。
        self.iff1 = 0          # 割り込み許可フリップフロップ
        self.iff2 = 0          # (RETN/NMI 用。LD A,I の PV へ反映)
        self.im = 0            # 割り込みモード 0/1/2
        self.i = 0             # I レジスタ (IM2 のベクタ上位バイト)
        self.halted = False    # HALT 待機中
        self._ei_block = False  # EI 直後 1 命令は割り込みを受理しない
        self.irq_poll = None   # callable(cpu) -> ベクタ下位バイト or None

    # ---- レジスタペア ----
    def get_bc(self):
        return (self.b << 8) | self.c

    def get_de(self):
        return (self.d << 8) | self.e

    def get_hl(self):
        return (self.h << 8) | self.l

    def set_bc(self, v):
        self.b, self.c = (v >> 8) & 0xFF, v & 0xFF

    def set_de(self, v):
        self.d, self.e = (v >> 8) & 0xFF, v & 0xFF

    def set_hl(self, v):
        self.h, self.l = (v >> 8) & 0xFF, v & 0xFF

    # ---- メモリ ----
    def rd(self, a):
        return self.mem[a & 0xFFFF]

    def wr(self, a, v):
        self.mem[a & 0xFFFF] = v & 0xFF

    def rd16(self, a):
        return self.rd(a) | (self.rd(a + 1) << 8)

    def wr16(self, a, v):
        self.wr(a, v & 0xFF)
        self.wr(a + 1, (v >> 8) & 0xFF)

    def fetch(self):
        v = self.rd(self.pc)
        self.pc = (self.pc + 1) & 0xFFFF
        return v

    def fetch16(self):
        v = self.fetch()
        return v | (self.fetch() << 8)

    def push(self, v):
        self.sp = (self.sp - 2) & 0xFFFF
        self.wr16(self.sp, v)

    def pop(self):
        v = self.rd16(self.sp)
        self.sp = (self.sp + 2) & 0xFFFF
        return v

    # ---- フラグ ----
    def set_szp(self, v):
        self.f = (self.f & ~(S | Z | PV)) | (v & S) | (Z if v == 0 else 0)
        if bin(v).count("1") % 2 == 0:
            self.f |= PV

    def add8(self, x, y, carry=0):
        r = x + y + carry
        self.f = 0
        if (r & 0xFF) == 0:
            self.f |= Z
        if r & 0x80:
            self.f |= S
        if r > 0xFF:
            self.f |= C
        if ((x & 0xF) + (y & 0xF) + carry) > 0xF:
            self.f |= H
        if (~(x ^ y) & (x ^ r)) & 0x80:
            self.f |= PV
        return r & 0xFF

    def sub8(self, x, y, carry=0):
        r = x - y - carry
        self.f = N
        if (r & 0xFF) == 0:
            self.f |= Z
        if r & 0x80:
            self.f |= S
        if r < 0:
            self.f |= C
        if ((x & 0xF) - (y & 0xF) - carry) < 0:
            self.f |= H
        if ((x ^ y) & (x ^ r)) & 0x80:
            self.f |= PV
        return r & 0xFF

    def inc8(self, v):
        r = (v + 1) & 0xFF
        self.f = (self.f & C) | (r & S) | (Z if r == 0 else 0)
        if (v & 0xF) == 0xF:
            self.f |= H
        if v == 0x7F:
            self.f |= PV
        return r

    def dec8(self, v):
        r = (v - 1) & 0xFF
        self.f = (self.f & C) | N | (r & S) | (Z if r == 0 else 0)
        if (v & 0xF) == 0:
            self.f |= H
        if v == 0x80:
            self.f |= PV
        return r

    def cond(self, cc):
        return [
            not self.f & Z, bool(self.f & Z),
            not self.f & C, bool(self.f & C),
            not self.f & PV, bool(self.f & PV),
            not self.f & S, bool(self.f & S),
        ][cc]

    # ---- r番号アクセス (B,C,D,E,H,L,(HL),A) ----
    def get_r(self, i):
        return [self.b, self.c, self.d, self.e, self.h, self.l,
                self.rd(self.get_hl()), self.a][i]

    def set_r(self, i, v):
        v &= 0xFF
        if i == 0:
            self.b = v
        elif i == 1:
            self.c = v
        elif i == 2:
            self.d = v
        elif i == 3:
            self.e = v
        elif i == 4:
            self.h = v
        elif i == 5:
            self.l = v
        elif i == 6:
            self.wr(self.get_hl(), v)
        else:
            self.a = v

    def get_ss(self, i):
        return [self.get_bc, self.get_de, self.get_hl, lambda: self.sp][i]()

    def set_ss(self, i, v):
        [self.set_bc, self.set_de, self.set_hl,
         lambda x: setattr(self, "sp", x)][i](v & 0xFFFF)

    def alu(self, op, v):
        if op == 0:
            self.a = self.add8(self.a, v)
        elif op == 1:
            self.a = self.add8(self.a, v, (self.f & C) and 1)
        elif op == 2:
            self.a = self.sub8(self.a, v)
        elif op == 3:
            self.a = self.sub8(self.a, v, (self.f & C) and 1)
        elif op == 4:
            self.a &= v
            self.set_szp(self.a)
            self.f = (self.f & ~(N | C)) | H
        elif op == 5:
            self.a ^= v
            self.set_szp(self.a)
            self.f &= ~(N | C | H)
        elif op == 6:
            self.a |= v
            self.set_szp(self.a)
            self.f &= ~(N | C | H)
        else:
            self.sub8(self.a, v)  # CP: 結果は捨てる

    def cb_op(self, op, v):
        """CBプレフィクスのローテート・シフト。新しい値と更新済みフラグを返す"""
        c_in = self.f & C
        if op == 0:  # RLC
            c = (v >> 7) & 1
            r = ((v << 1) | c) & 0xFF
        elif op == 1:  # RRC
            c = v & 1
            r = ((v >> 1) | (c << 7)) & 0xFF
        elif op == 2:  # RL
            c = (v >> 7) & 1
            r = ((v << 1) | (1 if c_in else 0)) & 0xFF
        elif op == 3:  # RR
            c = v & 1
            r = ((v >> 1) | (0x80 if c_in else 0)) & 0xFF
        elif op == 4:  # SLA
            c = (v >> 7) & 1
            r = (v << 1) & 0xFF
        elif op == 5:  # SRA
            c = v & 1
            r = ((v >> 1) | (v & 0x80)) & 0xFF
        elif op == 6:  # SLL(未定義命令)
            c = (v >> 7) & 1
            r = ((v << 1) | 1) & 0xFF
        else:  # SRL
            c = v & 1
            r = (v >> 1) & 0xFF
        self.set_szp(r)
        self.f = (self.f & ~(N | H | C)) | c
        return r

    def add16(self, x, y):
        r = x + y
        self.f = (self.f & (S | Z | PV)) | (C if r > 0xFFFF else 0)
        if ((x & 0xFFF) + (y & 0xFFF)) > 0xFFF:
            self.f |= H
        return r & 0xFFFF

    def _accept_int(self, vec):
        """マスカブル割り込みを受理する。iff をクリアし PC を退避して ISR へ。"""
        self.iff1 = 0
        self.iff2 = 0
        self.push(self.pc)
        if self.im == 2:
            ptr = ((self.i & 0xFF) << 8) | (vec & 0xFF)
            self.pc = self.rd16(ptr)
            self.cycles += 19
        else:  # IM 1 (IM 0 も最小実装として 0038H へ)
            self.pc = 0x0038
            self.cycles += 13

    def step(self):
        # ---- 割り込み(irq_poll 設定時のみ有効)----
        if self.irq_poll is not None:
            accept = self.iff1 and not self._ei_block
            self._ei_block = False
            vec = self.irq_poll(self) if accept else None
            if self.halted:
                if vec is not None:
                    self.halted = False
                    self.pc = (self.pc + 1) & 0xFFFF  # HALT の次へ復帰させる
                    self._accept_int(vec)
                else:
                    self.cycles += 4  # HALT 中は NOP 相当で時間だけ進める
                return
            if vec is not None:
                self._accept_int(vec)
                return
        if self.pc in self.hooks:
            if self.hooks[self.pc](self):
                self.pc = self.pop()
                self.cycles += 10  # RET 相当
                return
        pc0 = self.pc
        op = self.fetch()
        self.cycles += _BASE_T[op]

        if op == 0x00:  # NOP
            return
        if op == 0x76:
            if self.irq_poll is None:
                raise Trap("HALT", self)  # 割り込み機構なし: 従来どおり停止扱い
            self.halted = True
            self.pc = (self.pc - 1) & 0xFFFF  # PC を HALT に留め、INT で抜ける
            return
        if 0x40 <= op <= 0x7F:  # LD r,r'
            self.set_r((op >> 3) & 7, self.get_r(op & 7))
            return
        if 0x80 <= op <= 0xBF:  # ALU A,r
            self.alu((op >> 3) & 7, self.get_r(op & 7))
            return
        hi, lo = op >> 6, op & 7
        if hi == 0:
            q = (op >> 3) & 7
            if lo == 6:  # LD r,n
                self.set_r(q, self.fetch())
                return
            if lo == 4:  # INC r
                self.set_r(q, self.inc8(self.get_r(q)))
                return
            if lo == 5:  # DEC r
                self.set_r(q, self.dec8(self.get_r(q)))
                return
            if op in (0x01, 0x11, 0x21, 0x31):  # LD ss,nn
                self.set_ss(op >> 4, self.fetch16())
                return
            if op in (0x03, 0x13, 0x23, 0x33):  # INC ss
                self.set_ss(op >> 4, (self.get_ss(op >> 4) + 1) & 0xFFFF)
                return
            if op in (0x0B, 0x1B, 0x2B, 0x3B):  # DEC ss
                self.set_ss(op >> 4, (self.get_ss(op >> 4) - 1) & 0xFFFF)
                return
            if op in (0x09, 0x19, 0x29, 0x39):  # ADD HL,ss
                self.set_hl(self.add16(self.get_hl(), self.get_ss(op >> 4)))
                return
            if op == 0x0A:
                self.a = self.rd(self.get_bc())
                return
            if op == 0x1A:
                self.a = self.rd(self.get_de())
                return
            if op == 0x02:
                self.wr(self.get_bc(), self.a)
                return
            if op == 0x12:
                self.wr(self.get_de(), self.a)
                return
            if op == 0x3A:
                self.a = self.rd(self.fetch16())
                return
            if op == 0x32:
                self.wr(self.fetch16(), self.a)
                return
            if op == 0x2A:
                self.set_hl(self.rd16(self.fetch16()))
                return
            if op == 0x22:
                self.wr16(self.fetch16(), self.get_hl())
                return
            if op == 0x18:  # JR
                d = self.fetch()
                self.pc = (self.pc + (d - 256 if d > 127 else d)) & 0xFFFF
                return
            if op in (0x20, 0x28, 0x30, 0x38):  # JR cc
                d = self.fetch()
                if self.cond((op - 0x20) >> 3):
                    self.pc = (self.pc + (d - 256 if d > 127 else d)) & 0xFFFF
                    self.cycles += 5  # taken: 7T→12T
                return
            if op == 0x10:  # DJNZ
                d = self.fetch()
                self.b = (self.b - 1) & 0xFF
                if self.b:
                    self.pc = (self.pc + (d - 256 if d > 127 else d)) & 0xFFFF
                    self.cycles += 5  # taken: 8T→13T
                return
            if op == 0x07:  # RLCA
                c = (self.a >> 7) & 1
                self.a = ((self.a << 1) | c) & 0xFF
                self.f = (self.f & (S | Z | PV)) | c
                return
            if op == 0x0F:  # RRCA
                c = self.a & 1
                self.a = ((self.a >> 1) | (c << 7)) & 0xFF
                self.f = (self.f & (S | Z | PV)) | c
                return
            if op == 0x17:  # RLA
                c = (self.a >> 7) & 1
                self.a = ((self.a << 1) | (self.f & C)) & 0xFF
                self.f = (self.f & (S | Z | PV)) | c
                return
            if op == 0x1F:  # RRA
                c = self.a & 1
                self.a = ((self.a >> 1) | (0x80 if self.f & C else 0)) & 0xFF
                self.f = (self.f & (S | Z | PV)) | c
                return
            if op == 0x2F:  # CPL
                self.a ^= 0xFF
                self.f |= H | N
                return
            if op == 0x37:  # SCF
                self.f = (self.f & (S | Z | PV)) | C
                return
            if op == 0x3F:  # CCF
                self.f = (self.f & (S | Z | PV | C)) ^ C
                return
            if op == 0x08:  # EX AF,AF'
                self.a, self.a2, self.f, self.f2 = self.a2, self.a, self.f2, self.f
                return
        if hi == 3:
            if op == 0xC3:
                self.pc = self.fetch16()
                return
            if op == 0xCD:
                a = self.fetch16()
                self.push(self.pc)
                self.pc = a
                return
            if op == 0xC9:
                self.pc = self.pop()
                return
            if lo == 2:  # JP cc
                a = self.fetch16()
                if self.cond((op >> 3) & 7):
                    self.pc = a
                return
            if lo == 4:  # CALL cc
                a = self.fetch16()
                if self.cond((op >> 3) & 7):
                    self.push(self.pc)
                    self.pc = a
                    self.cycles += 7  # taken: 10T→17T
                return
            if lo == 0:  # RET cc
                if self.cond((op >> 3) & 7):
                    self.pc = self.pop()
                    self.cycles += 6  # taken: 5T→11T
                return
            if op in (0xC5, 0xD5, 0xE5, 0xF5):  # PUSH
                self.push([self.get_bc(), self.get_de(), self.get_hl(),
                           (self.a << 8) | self.f][(op >> 4) - 0xC])
                return
            if op in (0xC1, 0xD1, 0xE1, 0xF1):  # POP
                v = self.pop()
                i = (op >> 4) - 0xC
                if i == 3:
                    self.a, self.f = v >> 8, v & 0xFF
                else:
                    [self.set_bc, self.set_de, self.set_hl][i](v)
                return
            if lo == 6:  # ALU A,n
                self.alu((op >> 3) & 7, self.fetch())
                return
            if op == 0xEB:  # EX DE,HL
                d, e = self.d, self.e
                self.d, self.e = self.h, self.l
                self.h, self.l = d, e
                return
            if op == 0xD9:  # EXX
                self.b, self.b2 = self.b2, self.b
                self.c, self.c2 = self.c2, self.c
                self.d, self.d2 = self.d2, self.d
                self.e, self.e2 = self.e2, self.e
                self.h, self.h2 = self.h2, self.h
                self.l, self.l2 = self.l2, self.l
                return
            if op == 0xE3:  # EX (SP),HL
                v = self.rd16(self.sp)
                self.wr16(self.sp, self.get_hl())
                self.set_hl(v)
                return
            if op == 0xE9:  # JP (HL)
                self.pc = self.get_hl()
                return
            if op == 0xF9:  # LD SP,HL
                self.sp = self.get_hl()
                return
            if op == 0xF3:  # DI
                self.iff1 = self.iff2 = 0
                self._ei_block = False
                return
            if op == 0xFB:  # EI (割り込み許可は次の1命令後)
                self.iff1 = self.iff2 = 1
                self._ei_block = True
                return
            if op == 0xD3:  # OUT (n),A
                port = self.fetch()
                self.io_log.append((port, self.a))
                h = self.io_out_hooks.get(port)
                if h is not None:
                    h(self, self.a)  # OUT後の追加処理(ログのタイムスタンプ/Timer A捕捉等)
                return
            if op == 0xDB:  # IN A,(n)
                port = self.fetch()
                self.a = self.io_in[port](self) if port in self.io_in else 0xFF
                return
            if lo == 7:  # RST
                vec = op & 0x38
                if vec in self.rst_hooks:
                    self.rst_hooks[vec](self)
                    return
                raise Trap(f"RST {vec:02X}H", self)
            if op == 0xCB:
                sub = self.fetch()
                r, q = sub & 7, (sub >> 3) & 7
                # T-states (prefix の 4T はすでに加算済み)
                is_hl = (r == 6)
                if sub < 0x40:
                    self.cycles += 11 if is_hl else 4  # 計 15 / 8
                    self.set_r(r, self.cb_op(q, self.get_r(r)))
                elif sub < 0x80:  # BIT
                    self.cycles += 8 if is_hl else 4   # 計 12 / 8
                    v = self.get_r(r)
                    self.f = (self.f & C) | H | (0 if v & (1 << q) else Z | PV)
                elif sub < 0xC0:  # RES
                    self.cycles += 11 if is_hl else 4  # 計 15 / 8
                    self.set_r(r, self.get_r(r) & ~(1 << q))
                else:  # SET
                    self.cycles += 11 if is_hl else 4  # 計 15 / 8
                    self.set_r(r, self.get_r(r) | (1 << q))
                return
            if op == 0xED:
                sub = self.fetch()
                if sub in (0x4B, 0x5B, 0x6B, 0x7B):  # LD dd,(nn) 計20T
                    self.cycles += 16
                    self.set_ss((sub - 0x4B) >> 4, self.rd16(self.fetch16()))
                    return
                if sub in (0x43, 0x53, 0x63, 0x73):  # LD (nn),dd 計20T
                    self.cycles += 16
                    self.wr16(self.fetch16(), self.get_ss((sub - 0x43) >> 4))
                    return
                if sub == 0xB0:  # LDIR ループごとに21T、最後16T (prefix込み)
                    n = 0
                    while True:
                        self.wr(self.get_de(), self.rd(self.get_hl()))
                        self.set_hl(self.get_hl() + 1)
                        self.set_de(self.get_de() + 1)
                        self.set_bc(self.get_bc() - 1)
                        n += 1
                        if self.get_bc() == 0:
                            break
                    # prefix 4T はすでに加算済み。残り: (n-1)×17 + 12
                    self.cycles += max(0, (n - 1) * 17 + 12)
                    self.f &= ~(H | PV | N)
                    return
                if sub in (0xA1, 0xA9, 0xB1, 0xB9):  # CPI/CPD/CPIR/CPDR
                    step_ = 1 if sub in (0xA1, 0xB1) else -1
                    rep = sub in (0xB1, 0xB9)
                    n = 0
                    while True:
                        v = self.rd(self.get_hl())
                        r = (self.a - v) & 0xFF
                        self.set_hl(self.get_hl() + step_)
                        self.set_bc(self.get_bc() - 1)
                        self.f = (self.f & C) | N | (r & S) | (Z if r == 0 else 0)
                        if ((self.a & 0xF) - (v & 0xF)) < 0:
                            self.f |= H
                        if self.get_bc() != 0:
                            self.f |= PV
                        n += 1
                        if not rep or self.get_bc() == 0 or r == 0:
                            break
                    # CPI/CPD = 16T、CPIR/CPDR = 21T/16T
                    self.cycles += max(0, (n - 1) * 17 + 12)
                    return
                if sub == 0xB8:  # LDDR ループごとに21T、最後16T
                    n = 0
                    while True:
                        self.wr(self.get_de(), self.rd(self.get_hl()))
                        self.set_hl(self.get_hl() - 1)
                        self.set_de(self.get_de() - 1)
                        self.set_bc(self.get_bc() - 1)
                        n += 1
                        if self.get_bc() == 0:
                            break
                    self.cycles += max(0, (n - 1) * 17 + 12)
                    self.f &= ~(H | PV | N)
                    return
                if sub in (0x42, 0x52, 0x62, 0x72):  # SBC HL,ss 計15T
                    self.cycles += 11
                    x, y = self.get_hl(), self.get_ss((sub - 0x42) >> 4)
                    cy = self.f & C
                    r = x - y - cy
                    self.f = N
                    if (r & 0xFFFF) == 0:
                        self.f |= Z
                    if r & 0x8000:
                        self.f |= S
                    if r < 0:
                        self.f |= C
                    if ((x ^ y) & (x ^ r)) & 0x8000:
                        self.f |= PV
                    self.set_hl(r & 0xFFFF)
                    return
                if sub == 0x44:  # NEG 計8T
                    self.cycles += 4
                    self.a = self.sub8(0, self.a)
                    return
                if sub == 0x47:  # LD I,A 計9T
                    self.cycles += 5
                    self.i = self.a
                    return
                if sub == 0x57:  # LD A,I 計9T (PV<-IFF2)
                    self.cycles += 5
                    self.a = self.i
                    self.f = ((self.f & C) | (self.i & S) |
                              (Z if self.i == 0 else 0) | (PV if self.iff2 else 0))
                    return
                if sub in (0x46, 0x56, 0x5E):  # IM 0/1/2 計8T
                    self.cycles += 4
                    self.im = {0x46: 0, 0x56: 1, 0x5E: 2}[sub]
                    return
                if sub == 0x4D:  # RETI 計14T
                    self.cycles += 10
                    self.pc = self.pop()
                    return
                if sub == 0x45:  # RETN 計14T (IFF1<-IFF2)
                    self.cycles += 10
                    self.pc = self.pop()
                    self.iff1 = self.iff2
                    return
                raise Trap(f"未実装ED {sub:02X} at {pc0:04X}", self)
            if op in (0xDD, 0xFD):  # IX/IY (prefix 4T 加算済み)
                attr = "ix" if op == 0xDD else "iy"
                sub = self.fetch()
                xv = getattr(self, attr)
                if sub == 0x21:  # LD IX,nn 計14T
                    self.cycles += 10
                    setattr(self, attr, self.fetch16())
                    return
                if sub == 0x2A:  # LD IX,(nn) 計20T
                    self.cycles += 16
                    setattr(self, attr, self.rd16(self.fetch16()))
                    return
                if sub == 0x22:  # LD (nn),IX 計20T
                    self.cycles += 16
                    self.wr16(self.fetch16(), xv)
                    return
                if sub == 0xE5:  # PUSH IX 計15T
                    self.cycles += 11
                    self.push(xv)
                    return
                if sub == 0xE1:  # POP IX 計14T
                    self.cycles += 10
                    setattr(self, attr, self.pop())
                    return
                if sub == 0x23:  # INC IX 計10T
                    self.cycles += 6
                    setattr(self, attr, (xv + 1) & 0xFFFF)
                    return
                if sub == 0x2B:  # DEC IX 計10T
                    self.cycles += 6
                    setattr(self, attr, (xv - 1) & 0xFFFF)
                    return
                if sub in (0x09, 0x19, 0x29, 0x39):  # ADD IX,ss 計15T
                    self.cycles += 11
                    y = [self.get_bc(), self.get_de(), xv, self.sp][(sub >> 4)]
                    setattr(self, attr, self.add16(xv, y))
                    return
                if sub == 0xE9:  # JP (IX) 計8T
                    self.cycles += 4
                    self.pc = xv
                    return
                if sub == 0x36:  # LD (IX+d),n 計19T
                    self.cycles += 15
                    d = self.fetch()
                    d = d - 256 if d > 127 else d
                    self.wr(xv + d, self.fetch())
                    return
                if sub == 0x34 or sub == 0x35:  # INC/DEC (IX+d) 計23T
                    self.cycles += 19
                    d = self.fetch()
                    d = d - 256 if d > 127 else d
                    v = self.rd(xv + d)
                    self.wr(xv + d, self.inc8(v) if sub == 0x34 else self.dec8(v))
                    return
                if 0x40 <= sub <= 0x7F and (sub & 7 == 6 or (sub >> 3) & 7 == 6):
                    self.cycles += 15  # LD r,(IX+d) / LD (IX+d),r 計19T
                    d = self.fetch()
                    d = d - 256 if d > 127 else d
                    if sub & 7 == 6:  # LD r,(IX+d)
                        self.set_r((sub >> 3) & 7, self.rd(xv + d))
                    else:  # LD (IX+d),r
                        self.wr(xv + d, self.get_r(sub & 7))
                    return
                if 0x80 <= sub <= 0xBF and sub & 7 == 6:  # ALU A,(IX+d) 計19T
                    self.cycles += 15
                    d = self.fetch()
                    d = d - 256 if d > 127 else d
                    self.alu((sub >> 3) & 7, self.rd(xv + d))
                    return
                raise Trap(f"未実装{attr.upper()} {sub:02X} at {pc0:04X}", self)
        raise Trap(f"未実装オペコード {op:02X} at {pc0:04X}", self)

    def call(self, addr, max_steps=50_000_000):
        """addrをCALLし、対応するRETで戻るまで実行する"""
        magic = 0xFFFE
        self.push(magic)
        self.pc = addr
        steps = 0
        while self.pc != magic:
            self.step()
            steps += 1
            if steps > max_steps:
                raise Trap(f"ステップ上限超過 pc={self.pc:04X}", self)
