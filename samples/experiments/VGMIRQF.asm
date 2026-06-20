;=================================================
;VGMIRQF - 割り込み駆動VGM再生サンプル(F-1: メイン演奏 + ISRでSD補充)
;=================================================
;・設計方針 F-1: メインスレッドはVGM解析+音源書込み+Timer A tick の polling で
;  wait を消費する。Timer A IRQ ハンドラ(ISR)は SD 1バイト読み+リングバッファ
;  補充+tickカウンタ++ に専念する。HALTは使わない(VGMIRQの初版=HALT方式は
;  SD I/O律速で実用テンポにならなかったため方針転換した)。
;・ウェイトは Timer A を一定周期(SAMPLES_PER_TICK サンプル)で連続動作させ、
;  ISRが進める tick カウンタをメインが busy-poll して刻む。端数は WCREDIT で繰越。
;・SDは「ISRだけが触る」。メインのGETBはリングバッファからのみ読み、空のときは
;  ISRの補充をスピン待ちする(STRM_READ をメインから呼ぶと ISR と再入衝突する)。
;・リングバッファは ISR(生産者)とメイン(消費者)が共有するため、消費側
;  RB_GET を IRQ稼働中のみ DI/EI で囲って RB_CNT 更新の競合を防ぐ(ISRは
;  割り込み禁止状態で走るので生産側は原子的)。
;・音源(YM2203)レジスタ書きは OUT 80H(アドレス)→OUT 81H(データ)の2段書き。
;  ISRも27H(Timer A flagリセット)を書くため、メインの2段書きの間にISRが割り込むと
;  レジスタラッチが壊れる。よって .OPN の2段書きは DI/EI で保護する。
;・I=80HのままPC-8001の$8000台RAM上のIM2ベクタテーブルを使う(VGMIRQと同じ)。
;  INT4..7のうち空き1本のvectorエントリ2バイトだけを再生開始時に上書きし、
;  終了時に元値を復元。232C(8251)用エントリには触れずシリアル受信と共存できる。
;・使い方: LOAD "VGMIRQF.CMT" :(必要ならCD): モニタG9000
;   現在ディレクトリの*.VGM一覧 → 番号+Enterで再生 → 0/Enterで終了
;・POKE点: 9003H=IVR_FMTAV(vector番号) 9004H=SPTV(1tickのサンプル数)
;         9005H/9006H=TPSV_LO/TPSV_HI(TICKS_PER_SAMPLE校正、テンポ微調整)
;         9007H=FILL_PER_TICKV(1tickあたりのSD補充バイト数)
;   ・SPTV(9004H)大=CPU占有減/wait粗く/補充レート低、小=CPU占有増/wait細かく/補充多
;   ・FILL_PER_TICKV(9007H)大=補充レート増(枯渇対策)だがISR時間増
;・ヘッダ=header.md コマンド=commands.md 入出力=sound-io.md (docs/vgm/)
;=================================================

STRM_OPEN	EQU	6005H		;ストリームを開く
STRM_READ	EQU	6008H		;1バイト取得
STRM_CLOSE	EQU	600BH		;ストリームを閉じる
STRM_DIRLIST	EQU	600EH		;ディレクトリ一括取得

OPN_ADDR	EQU	80H		;YM2203 レジスタ番号/ステータス
OPN_DATA	EQU	81H		;YM2203 データ
PSG_ADDR	EQU	0A0H		;PSG#1 レジスタ番号
PSG_DATA	EQU	0A1H		;PSG#1 データ

CR		EQU	0DH
LF		EQU	0AH
BASIC		EQU	0081H		;BASIC復帰(モニタG/直接実行どちらでも安全)
KEYWAIT		EQU	0F75H		;1文字入力待ち A<-コード
MAXFILES	EQU	40H		;一覧の最大ファイル数(64)

;--- YM2203 Timer A レジスタ (docs/vgm/sound-io.md / YM2203 datasheet) ---
;27Hビット配置: bit0=LoadA, bit2=IRQEN A, bit4=ResetA
TA_REG_HI	EQU	24H		;Timer A 高位8bit
TA_REG_LO	EQU	25H		;Timer A 低位2bit
TA_REG_CTRL	EQU	27H		;モード/制御
TA_CTRL_RUN_IRQEN	EQU	00000101B	;LoadA=1, IRQEN A=1(連続動作)
TA_CTRL_STOP_RESET	EQU	00010000B	;ResetA=1
TA_FLAG_RESET_A_MASK	EQU	00010000B	;bit4 (Timer A flag reset)

;--- VGMサンプル -> Timer A tick 変換 ---
;1サンプル = 1/44100s ≒ 22.676us / Timer A 1 tick = 72/master ≒ 20.11us(3.58MHz)
;ticks_per_sample ≒ 1.128 / *256固定小数: round(1.128*256)=289=0x121
TICKS_PER_SAMPLE_X256	EQU	289

;--- IM2 ベクタテーブル ($8000台RAM、N-BASICが配置) ---
IVT_PAGE	EQU	80H		;Iレジスタ値(=テーブルページ)
IVR_FMTA_DEFAULT	EQU	04H	;INT4..7のうちFM Timer A用に選んだvector

;--- リングバッファ ---
RBUF_SIZE	EQU	4500H		;約17.25KB
INITFILL	EQU	2000H		;起動時部分プリフィル(8KB)

;--- F-1 パラメータ初期値 ---
SAMPLES_PER_TICK	EQU	80	;1tick=80サンプル≒1.81ms(周期/CPU占有のスイートスポット)
FILL_PER_TICK	EQU	01H		;1tickあたりのSD補充バイト数

;--- 進行状況表示 / セーフティ(実機デバッグ用。RST 18Hで1文字出力)---
;PROGRESS=1 で再生開始までの段階マーカー O/H/P/I を表示し、
;Timer A tick が来ない/バッファ枯渇したらタイムアウトで X/U を出して先へ進む
;(ハードハングを防ぎ、ISR が回っているかを画面で切り分けられる)。
;  O=STRM_OPEN H=ヘッダ解析 P=プレフィル I=IRQ設定 → PLAY
;  X=Timer A tick が来ない(ISR/割り込みが回っていない)
;  U=バッファ枯渇(ISR が SD 補充できていない)
PROGRESS	EQU	1
CH_O	EQU	4FH		;'O'
CH_H	EQU	48H		;'H'
CH_P	EQU	50H		;'P'
CH_I	EQU	49H		;'I'
CH_X	EQU	58H		;'X'
CH_U	EQU	55H		;'U'

	ORG	9000H

	JP	START			;9000H 実行エントリ(モニタG9000)
IVR_FMTAV:	DB	IVR_FMTA_DEFAULT	;9003H POKE: FM Timer A IRQ vector番号
SPTV:		DB	SAMPLES_PER_TICK	;9004H POKE: 1tickのサンプル数(Timer A周期)
TPSV_LO:	DB	33		;9005H POKE: TICKS_PER_SAMPLE_X256 の低位(=33で289)
TPSV_HI:	DB	1		;9006H POKE: TICKS_PER_SAMPLE_X256 の高位(=1で +256)
FILL_PER_TICKV:	DB	FILL_PER_TICK	;9007H POKE: 1tickあたりのSD補充バイト数

START:
	;ここでは DI しない。IRQ_SETUP まではISR(生産者)が存在せずリングバッファの
	;競合は起きないため、割り込みは IRQ_ACTIVE ゲートだけで十分。START で DI すると
	;N-BASIC の KEYWAIT 等が割り込み依存の場合にメニューがハングする(実績のある
	;VGMPLAY/VGMIRQ も START では DI していない)。
	LD	(SAVSP),SP		;BASIC復帰用のSP保存
	LD	SP,STACK_TOP		;専用スタックへ
	XOR	A
	LD	(IRQ_ACTIVE),A		;割り込み稼働フラグ=0

MENU:
	CALL	BUILD_LIST		;*.VGM一覧表示、(LISTCNT)=件数
	LD	A,(LISTCNT)		;0件なら終了
	OR	A
	JP	Z,BASIC
	CALL	READ_NUM		;HL=入力番号(1始まり、0/EnterでBASICへ)
	LD	A,H			;256以上は無視して再表示
	OR	A
	JR	NZ,MENU
	LD	A,L
	OR	A
	JP	Z,BASIC			;0で終了
	LD	A,(LISTCNT)		;番号>件数なら再表示
	CP	L
	JR	C,MENU
	LD	A,L			;K番目(1始まり)のVGMを選ぶ
	CALL	GET_NTH_VGM		;PLAYNAMEへ
	JR	C,MENU
	CALL	PLAY_FILE		;再生(選択しても次へ戻る)
	JR	MENU

;-------------------------------------------------
;正常終了(再生終了/EOF)
;-------------------------------------------------
DONE:
	LD	SP,(PLAYSP)		;再生中の脱出点へ
	CALL	IRQ_TEARDOWN		;割り込み機構を元に戻す
	CALL	STRM_CLOSE
	LD	HL,MSG_END
	CALL	PUTS
	RET				;メニューへ戻る

;-------------------------------------------------
;異常終了
;IN  HL=メッセージ
;-------------------------------------------------
ABORT:
	LD	SP,(PLAYSP)		;再生中の脱出点へ
	PUSH	HL
	CALL	IRQ_TEARDOWN
	CALL	STRM_CLOSE
	POP	HL
	CALL	PUTS
	RET				;メニューへ戻る

;-------------------------------------------------
;ヘッダ解析(docs/vgm/header.md の最小解析範囲)
;・識別子を確認し、バージョンからデータ開始位置を求めて読み進める
;-------------------------------------------------
PARSE_HDR:
	LD	HL,IDENT		;識別子 "Vgm " の確認
	LD	B,4
.ID:	CALL	GETB
	CP	(HL)
	JR	NZ,.NOTVGM
	INC	HL
	DJNZ	.ID
	LD	DE,4			;04H-07H(EOFオフセット)を読み捨て
	CALL	SKIP
	CALL	GETB			;08H- バージョン(BCD) 下位ワード
	LD	C,A
	CALL	GETB
	LD	B,A			;BC=バージョン下位ワード
	CALL	GETB			;上位2バイトは読み捨て
	CALL	GETB
	LD	H,B			;バージョン1.50未満なら旧形式
	LD	L,C
	LD	DE,0150H
	OR	A
	SBC	HL,DE
	JR	C,.OLD
	LD	DE,0028H		;0CH-33Hを読み捨て
	CALL	SKIP
	CALL	GETB			;34H- データ開始オフセット
	LD	E,A
	CALL	GETB
	LD	D,A			;DE=オフセット下位ワード
	CALL	GETB			;上位2バイトが0以外なら異常
	LD	C,A
	CALL	GETB
	OR	C
	JR	NZ,.BADHDR
	EX	DE,HL			;残り読み捨て先=オフセット-4(38Hまで読込済み)
	LD	DE,4
	OR	A
	SBC	HL,DE
	JR	C,.BADHDR		;オフセットが4未満なら異常
	EX	DE,HL
	JP	SKIP			;データ開始位置まで読み捨てて戻る

.OLD:	LD	DE,0034H		;旧形式はデータ開始40H固定。0CH-3Fを読み捨て
	JP	SKIP

.NOTVGM:	LD	HL,MSG_NOTVGM
	JP	ABORT
.BADHDR:	LD	HL,MSG_BADHDR
	JP	ABORT

;-------------------------------------------------
;再生ループ(docs/vgm/commands.md のコマンド表)
;-------------------------------------------------
PLAY:
.LOOP:	CALL	GETB			;コマンド取得
	CP	66H			;終了コマンド
	JP	Z,DONE
	CP	55H			;YM2203書き込み
	JR	Z,.OPN
	CP	0A0H			;PSG書き込み
	JR	Z,.PSG
	CP	61H			;ウェイト(サンプル数指定)
	JR	Z,.W61
	CP	62H			;ウェイト(735サンプル=1/60s)
	JR	Z,.W62
	CP	63H			;ウェイト(882サンプル=1/50s)
	JR	Z,.W63
	LD	C,A			;C<-コマンド退避
	AND	0F0H
	CP	70H			;70H-7FH 短ウェイト
	JR	Z,.W7X
	CP	80H			;80H-8FH YM2612 DAC+ウェイト(対象外なので無視)
	JR	Z,.LOOP
	LD	A,C
	JP	SKIP_CMD		;その他は読み飛ばし規則へ

.OPN:	CALL	GETB			;レジスタ番号
	LD	(OPNREG),A
	CALL	GETB			;データ値
	LD	(OPNDAT),A
.BUSY:	IN	A,(OPN_ADDR)		;BUSY(bit7)が下りるまで
	RLCA
	JR	C,.BUSY
	;2段書きの間にISRが27Hを書くとラッチが壊れるためDIで保護する
	DI
	LD	A,(OPNREG)		;レジスタ番号を出力
	OUT	(OPN_ADDR),A
	LD	A,(OPNREG)		;ダミー読みで短い待ち
	LD	A,(OPNDAT)		;データ値を出力
	OUT	(OPN_DATA),A
	EI
	JP	PLAY.LOOP

.PSG:	CALL	GETB			;レジスタ番号を出力(A0H/A1HはISRが触れないため保護不要)
	OUT	(PSG_ADDR),A
	CALL	GETB			;データ値を出力
	OUT	(PSG_DATA),A
	JP	PLAY.LOOP

.W61:	CALL	GETB			;DE<-サンプル数
	LD	E,A
	CALL	GETB
	LD	D,A
	CALL	WAIT_DE_POLL
	JP	PLAY.LOOP
.W62:	LD	DE,735			;1/60秒
	CALL	WAIT_DE_POLL
	JP	PLAY.LOOP
.W63:	LD	DE,882			;1/50秒
	CALL	WAIT_DE_POLL
	JP	PLAY.LOOP
.W7X:	LD	A,C			;(下位4bit+1)サンプル
	AND	0FH
	INC	A
	LD	E,A
	LD	D,0
	CALL	WAIT_DE_POLL
	JP	PLAY.LOOP

;-------------------------------------------------
;非対応コマンドの読み飛ばし(docs/vgm/commands.md の規則)
;IN  A=コマンド
;-------------------------------------------------
SKIP_CMD:
	CP	30H			;00H-2FH:未知
	JR	C,.BAD
	CP	40H			;30H-3FH:1バイト
	JR	C,.S1
	CP	4FH			;40H-4EH:未知
	JR	C,.BAD
	CP	51H			;4FH,50H:1バイト
	JR	C,.S1
	CP	60H			;51H-5FH:2バイト
	JR	C,.S2
	CP	64H			;64H:3バイト
	JR	Z,.S3
	CP	67H			;67H:データブロック
	JR	Z,.BLK
	CP	90H			;60H,65H,68H-6FH:未知
	JR	C,.BAD
	CP	96H			;90H-95H:DACストリーム
	JR	C,.S9X
	CP	0A1H			;96H-A0H:未知
	JR	C,.BAD
	CP	0C0H			;A1H-BFH:2バイト
	JR	C,.S2
	CP	0E0H			;C0H-DFH:3バイト
	JR	C,.S3
.S4:	CALL	GETB			;E0H-FFH:4バイト
.S3:	CALL	GETB
.S2:	CALL	GETB
.S1:	CALL	GETB
	JP	PLAY.LOOP

.BAD:	LD	HL,MSG_BADCMD		;未知コマンドは解釈ずれのため中断
	JP	ABORT

.S9X:	SUB	90H			;90H-95Hのオペランド数テーブルを参照
	LD	HL,TBL9X
	LD	E,A
	LD	D,0
	ADD	HL,DE
	LD	B,(HL)
.S9L:	CALL	GETB
	DJNZ	.S9L
	JP	PLAY.LOOP

.BLK:	CALL	GETB			;66H(互換用バイト)
	CALL	GETB			;ブロックタイプ
	LD	HL,BLKSZ		;サイズ4バイト(リトルエンディアン)
	LD	B,4
.BSZ:	CALL	GETB
	LD	(HL),A
	INC	HL
	DJNZ	.BSZ
.BSKIP:	LD	HL,BLKSZ		;サイズが0になるまで読み捨て
	LD	B,4
	XOR	A
.BZ:	OR	(HL)
	INC	HL
	DJNZ	.BZ
	OR	A
	JP	Z,PLAY.LOOP
	LD	HL,BLKSZ		;サイズを1減らす(4バイトの繰り下げ)
	LD	A,(HL)
	SUB	1
	LD	(HL),A
	JR	NC,.BRD
	LD	B,3
.BD:	INC	HL
	LD	A,(HL)
	SBC	A,0
	LD	(HL),A
	JR	NC,.BRD
	DJNZ	.BD
.BRD:	CALL	GETB
	JR	.BSKIP

;-------------------------------------------------
;指定バイト数の読み捨て
;IN  DE=バイト数
;-------------------------------------------------
SKIP:	LD	A,D
	OR	E
	RET	Z
	CALL	GETB
	DEC	DE
	JR	SKIP

;-------------------------------------------------
;1バイト取得(EOFは再生終了として扱う)
;OUT A=取得した値
;・IRQ稼働中はISRがリングバッファを補充する。バッファ空のときは STRM_READ を
;  メインから呼ぶとISRと再入衝突するため、ISRの補充をスピン待ちする。
;・IRQ非稼働中(PARSE_HDR等、ISR未武装)はフォールバックで直接STRM_READする。
;OUT A=取得値 / 破壊なし(呼び出し側のBC/DE/HL/IXは保存)
;-------------------------------------------------
GETB:	PUSH	HL			;HL/DE/BCを保存(呼び出し側がHLを多用)
	PUSH	DE
	PUSH	BC
  IF PROGRESS
	LD	HL,0			;空スピンのタイムアウト計数をリセット
	LD	(GETB_TO),HL
  ENDIF
.try:	CALL	RB_GET_SAFE		;リングバッファから取得(IRQ中はDI/EIで排他)
	JR	NC,.GOT
	LD	A,(RB_EOF)		;空かつ読みが終端に達していれば
	OR	A
	JR	NZ,.EOF			;再生終了へ
	LD	A,(IRQ_ACTIVE)		;IRQ稼働中?
	OR	A
	JR	Z,.fallback		;非稼働中: 直接読み(空かつ終端でない)
  IF PROGRESS
	LD	HL,(GETB_TO)		;稼働中の空: ISR補充待ち。タイムアウトで打ち切る
	INC	HL
	LD	(GETB_TO),HL
	LD	A,H
	OR	L
	JR	NZ,.try			;65536回(約6ms)まではISR補充を待つ
	LD	A,CH_U			;'U' = バッファ枯渇(ISRがSD補充できていない)
	RST	18H
	JR	.EOF			;枯渇は終了扱いでメニューへ(ハードハング防止)
  ELSE
	JR	.try			;稼働中: ISRの補充を待って再取得
  ENDIF
.fallback:
	CALL	STRM_READ		;非稼働中の直接読み
	JR	C,.RDEOF
.GOT:	POP	BC
	POP	DE
	POP	HL
	RET				;A=取得値
.RDEOF:	LD	A,0FFH			;直接読みでEOF
	LD	(RB_EOF),A
.EOF:	POP	BC
	POP	DE
	POP	HL
	JP	DONE			;EOFは再生終了

;=================================================
;WAIT_DE_POLL - Timer A の tick カウンタを polling して DE サンプル待つ(F-1)
; IN  : DE = 待つサンプル数
; OUT : なし
; 破壊: AF, BC, DE, HL (呼出側 .W6x は直後に PLAY.LOOP へ飛ぶため問題なし)
;・1 tick = (SPTV) サンプル。ISRが tick ごとに TA_TICKS を進める。
;・端数は WCREDIT に繰り越し、平均テンポを正確に保つ(tickが粗くても誤差が
;  蓄積しない)。
;=================================================
WAIT_DE_POLL:
	;まず WCREDIT(前回オーバーシュートの繰越)から消費: DE = DE - WCREDIT
	LD	HL,(WCREDIT)
	LD	A,E
	SUB	L
	LD	E,A
	LD	A,D
	SBC	A,H
	LD	D,A
	JR	C,.allcredit		;WCREDIT > DE: クレジットだけで全消化
	LD	HL,0			;クレジット使い切り
	LD	(WCREDIT),HL
.spin:
	LD	A,D			;残り0なら終了
	OR	E
	RET	Z
	CALL	WAIT_ONE_TICK		;1 tick(=SPTVサンプル)経過を待つ
	LD	A,(SPTV)		;BC = SPTV
	LD	C,A
	LD	B,0
	LD	A,E			;DE -= SPTV
	SUB	C
	LD	E,A
	LD	A,D
	SBC	A,B
	LD	D,A
	JR	NC,.spin		;まだ残っている
.allcredit:
	;オーバーシュート: 余分に待った分(=-DE)を WCREDIT へ繰り越す
	LD	HL,0
	OR	A			;CY=0
	SBC	HL,DE			;HL = 0 - DE
	LD	(WCREDIT),HL
	RET

;-------------------------------------------------
;WAIT_ONE_TICK - ISR が TA_TICKS を1進めるまでスピンする
; IN  : なし(EI 状態であること)
; OUT : なし
; 破壊: AF のみ(BCは保存)
;-------------------------------------------------
WAIT_ONE_TICK:
	PUSH	BC
	PUSH	HL
	LD	A,(TA_TICKS)
	LD	C,A
	LD	B,08H			;外側タイムアウト(8×65536回 ≒ 約13ms。正常tick 1.81msより十分長い)
.w0:	LD	HL,0
.w:	LD	A,(TA_TICKS)
	CP	C
	JR	NZ,.done		;tickが来た(ISRが++した)
	INC	HL
	LD	A,H
	OR	L
	JR	NZ,.w
	DJNZ	.w0
  IF PROGRESS
	LD	A,CH_X			;'X' = tickが来ない(ISR/Timer Aが回っていない)。先へ進む
	RST	18H
  ENDIF
.done:	POP	HL
	POP	BC
	RET

;=================================================
;CALC_TA_NA - (SPTV) サンプル周期になる Timer A プリロード値 NA を求める
; OUT : HL = NA (= 1024 - SPTV*TICKS_PER_SAMPLE/256)、1..1023 にクランプ
; 破壊: AF, BC, DE, HL
;=================================================
CALC_TA_NA:
	LD	A,(SPTV)		;DE = SPTV
	LD	E,A
	LD	D,0
	CALL	MUL_DE_TPS		;HL = (SPTV * TPS) >> 8 = tick数(DEは保存)
	EX	DE,HL			;DE = tick数
	LD	HL,1024
	OR	A			;CY=0
	SBC	HL,DE			;HL = 1024 - tick数 = NA
	LD	A,H			;NA<=0 なら1にクランプ
	OR	L
	RET	NZ
	LD	HL,1
	RET

;-------------------------------------------------
;MUL_DE_TPS - HL = (DE * TPS) >> 8  (TPS=9005H/9006H、TPSV_HI=1 前提)
; → HL = DE + (DE * TPSV_LO) >> 8
; IN  : DE / OUT : HL / 破壊: AF, BC。DE は保存
;-------------------------------------------------
MUL_DE_TPS:
	PUSH	BC
	PUSH	DE
	LD	A,(TPSV_LO)
	LD	C,A			;C = TPSV_LO (8bit 乗数)
	LD	HL,0			;HL = 累算下位
	XOR	A			;A = 累算上位
	LD	B,8
.lp:	ADD	HL,HL
	ADC	A,A			;24bit累算: A:HL <<= 1
	SLA	C
	JR	NC,.skip
	ADD	HL,DE
	ADC	A,0
.skip:	DJNZ	.lp
	LD	L,H			;>>8: 上位16bitをHLへ
	LD	H,A
	POP	DE
	ADD	HL,DE			;HL += DE (TPSV_HI=1 ぶん)
	POP	BC
	RET

;-------------------------------------------------
;OPN_WR_RD - YM2203 1レジスタ書込み(BUSY待ちあり)
; IN  : D = レジスタ番号, E = データ / 破壊: AF のみ
;-------------------------------------------------
OPN_WR_RD:
	PUSH	AF
.busy:	IN	A,(OPN_ADDR)
	RLCA
	JR	C,.busy
	LD	A,D
	OUT	(OPN_ADDR),A
	LD	A,D			;ダミー命令で短い待ち
	LD	A,E
	OUT	(OPN_DATA),A
	POP	AF
	RET

;-------------------------------------------------
;TA_LOAD_HL - 24H/25HへTimer A 10bitプリロード書込み(BUSY待ちあり)
; IN  : HL = プリロード値(0..1023) / 破壊: AF のみ
;-------------------------------------------------
TA_LOAD_HL:
	PUSH	BC
	PUSH	DE
	PUSH	HL
	PUSH	AF
	LD	C,L			;Cにオリジナル下位を退避
	SRL	H			;高位 = HL >> 2
	RR	L
	SRL	H
	RR	L
	LD	D,TA_REG_HI
	LD	E,L
	CALL	OPN_WR_RD
	LD	A,C			;低位2bit
	AND	03H
	LD	D,TA_REG_LO
	LD	E,A
	CALL	OPN_WR_RD
	POP	AF
	POP	HL
	POP	DE
	POP	BC
	RET

;-------------------------------------------------
;TA_START - 27H <- LoadA=1, IRQEN A=1(連続動作)/ 破壊: AF のみ
;-------------------------------------------------
TA_START:
	PUSH	DE
	LD	D,TA_REG_CTRL
	LD	E,TA_CTRL_RUN_IRQEN
	LD	A,E
	LD	(TA_CTRL_SHADOW),A
	CALL	OPN_WR_RD
	POP	DE
	RET

;-------------------------------------------------
;TA_STOP - Timer A停止+flagリセット / 破壊: AF のみ
;-------------------------------------------------
TA_STOP:
	PUSH	DE
	LD	D,TA_REG_CTRL
	LD	E,TA_CTRL_STOP_RESET
	LD	A,E
	LD	(TA_CTRL_SHADOW),A
	CALL	OPN_WR_RD
	LD	D,TA_REG_CTRL		;resetパルスを落として通常状態へ
	LD	E,0
	XOR	A
	LD	(TA_CTRL_SHADOW),A
	CALL	OPN_WR_RD
	POP	DE
	RET

;-------------------------------------------------
;IRQ_SETUP - ベクタ退避→自前ISR設置→Timer A連続起動→EI
;・F-1: Timer A を (SPTV) サンプル周期で連続動作させ、ISRが tick++ とSD補充を行う
;-------------------------------------------------
IRQ_SETUP:
	DI
	LD	A,(IVR_FMTAV)		;HL = $8000 + (IVR_FMTAV)
	LD	L,A
	LD	H,IVT_PAGE
	LD	(IVT_PTR),HL
	LD	E,(HL)			;既存エントリを退避
	INC	HL
	LD	D,(HL)
	LD	(SAVED_VEC_FMTA),DE
	LD	HL,(IVT_PTR)		;自前ハンドラを書き込む
	LD	DE,ISR_FMTA
	LD	(HL),E
	INC	HL
	LD	(HL),D
	LD	A,IVT_PAGE		;I=80H, IM 2 を確定
	LD	I,A
	IM	2
	XOR	A			;tickカウンタ初期化
	LD	(TA_TICKS),A
	LD	HL,0			;クレジット初期化
	LD	(WCREDIT),HL
	CALL	CALC_TA_NA		;HL = SPTVサンプル周期のNA
	LD	(TA_NA),HL		;ISRが毎tick再ロードするため保存
	CALL	TA_STOP
	CALL	TA_LOAD_HL		;24H/25Hへプリロード
	CALL	TA_START		;LoadA|IRQEN で起動(以後はISRが毎tick再起動)
	LD	A,0FFH			;割り込み稼働フラグON(GETB/RB_GET_SAFEの排他切替)
	LD	(IRQ_ACTIVE),A
	EI
	RET

;-------------------------------------------------
;IRQ_TEARDOWN - Timer A停止→ベクタ復元→IM 1→EI
;-------------------------------------------------
IRQ_TEARDOWN:
	DI
	XOR	A			;割り込み稼働フラグOFF(先に下げる)
	LD	(IRQ_ACTIVE),A
	CALL	TA_STOP
	LD	HL,(IVT_PTR)		;ベクタを元に戻す
	LD	DE,(SAVED_VEC_FMTA)
	LD	(HL),E
	INC	HL
	LD	(HL),D
	IM	1
	EI
	RET

;-------------------------------------------------
;ISR_FMTA - Timer A 割り込みハンドラ(F-1の主役)
;・Timer A flagリセット → SD補充(FILL_PER_TICKVバイト) → tick++ → EI/RETI
;・STRM_READがBC/DE/HLを使うため、表レジスタはEX AF,AF'+EXXで退避する
;  (STRM_READ自身がIXを退避する)
;-------------------------------------------------
ISR_FMTA:
	EX	AF,AF'
	EXX				;BC/DE/HLを裏レジスタへ退避
	;Timer A を停止→リロード→再起動して次のオーバーフローを確実に再武装する。
	;連続(auto-reload)モードで flag リセットのみだと実機で2発目以降の IRQ エッジが
	;出ない(VGMIRQ が per-chunk で stop→load→start するのと同じ理由)。
	;TA_STOP が ResetA でフラグ消去+LoadA=0、TA_START で LoadA|IRQEN 再開。
	CALL	TA_STOP
	LD	HL,(TA_NA)
	CALL	TA_LOAD_HL
	CALL	TA_START
	;SD補充: FILL_PER_TICKVバイトだけ満タン/EOFでなければ読む
	LD	A,(FILL_PER_TICKV)
	OR	A
	JR	Z,.notick
	LD	B,A
.fl:	CALL	RB_TRYFILL1		;CY=1で1バイト補充、CY=0で満タン/EOF
	JR	NC,.tick
	DJNZ	.fl
.tick:	;tickカウンタ++(メインのWAIT_ONE_TICKが監視)
	LD	HL,TA_TICKS
	INC	(HL)
.notick:
	EXX
	EX	AF,AF'
	EI
	RETI

;=================================================
;リングバッファ(ISR=生産者 / メイン=消費者)
;=================================================
RB_INIT:
	LD	HL,RBUF
	LD	(RB_RDP),HL
	LD	(RB_WRP),HL
	LD	HL,0
	LD	(RB_CNT),HL
	XOR	A
	LD	(RB_EOF),A
	RET

;[RB]1バイト格納(満タンでないこと)。ISR(生産者)が呼ぶ / 破壊: AF。HL/DE保存
RB_PUT:
	PUSH	HL
	PUSH	DE
	LD	HL,(RB_WRP)
	LD	(HL),A
	INC	HL
	LD	DE,RBUF_END
	LD	A,H
	CP	D
	JR	NZ,.NW
	LD	A,L
	CP	E
	JR	NZ,.NW
	LD	HL,RBUF
.NW:	LD	(RB_WRP),HL
	LD	HL,(RB_CNT)
	INC	HL
	LD	(RB_CNT),HL
	POP	DE
	POP	HL
	RET

;[RB]1バイト取得 OUT A=値,CY=0 / CY=1:空。破壊: AF,BC,DE,HL
RB_GET:
	LD	HL,(RB_CNT)
	LD	A,H
	OR	L
	SCF				;空ならCY=1
	RET	Z
	LD	HL,(RB_RDP)
	LD	B,(HL)			;値をB
	INC	HL
	LD	DE,RBUF_END
	LD	A,H
	CP	D
	JR	NZ,.NW
	LD	A,L
	CP	E
	JR	NZ,.NW
	LD	HL,RBUF
.NW:	LD	(RB_RDP),HL
	LD	HL,(RB_CNT)
	DEC	HL
	LD	(RB_CNT),HL
	LD	A,B			;値をA
	OR	A			;CY=0
	RET

;[RB]RB_GETの排他ラッパ(メイン消費者専用)
;・IRQ稼働中はISR(RB_PUT)とRB_CNT更新が競合するためDI/EIで囲う。
;  ISRは割り込み禁止状態で走るので生産側は原子的、消費側だけ保護すればよい。
;・非稼働中(IRQ_ACTIVE=0)はそのままRB_GET。
;OUT A=値,CY=0 / CY=1:空。破壊: AF,BC,DE,HL
RB_GET_SAFE:
	LD	A,(IRQ_ACTIVE)
	OR	A
	JP	Z,RB_GET		;非稼働中はそのまま
	DI
	CALL	RB_GET
	EI
	RET

;[RB]満タンでなければ1バイトだけ補充 OUT CY=1:読んで格納 / CY=0:満タンorEOF
;・ISRから呼ばれる(割り込み禁止状態)。STRM_READがBC/DE/HL/IXを保存する
RB_TRYFILL1:
	LD	A,(RB_EOF)
	OR	A
	JR	NZ,.NO
	PUSH	HL
	PUSH	DE
	LD	HL,(RB_CNT)
	LD	DE,RBUF_SIZE
	OR	A
	SBC	HL,DE
	POP	DE
	POP	HL
	JR	NC,.NO			;満タン
	CALL	STRM_READ
	JR	C,.EOF
	CALL	RB_PUT
	SCF				;CY=1:読んだ
	RET
.EOF:	LD	A,0FFH
	LD	(RB_EOF),A
.NO:	OR	A			;CY=0
	RET

;[RB]起動時の部分プリフィル(INITFILLまで先読み。残りは再生中にISRが補充)
;・IRQ_SETUP前に呼ぶこと(まだISRは動いていないのでメインが直接補充する)
RB_PREFILL:
.pf:	CALL	RB_TRYFILL1
	JR	NC,.done
	LD	HL,(RB_CNT)
	LD	DE,INITFILL
	OR	A
	SBC	HL,DE
	JR	C,.pf
.done:	RET

;=================================================
;PLAY_FILE - OPEN→ヘッダ解析→プリフィル→IRQ設置→PLAY
;=================================================
PLAY_FILE:
	LD	HL,PLAYNAME
	CALL	STRM_OPEN
	JR	C,.nf
  IF PROGRESS
	LD	A,CH_O			;'O' = STRM_OPEN 成功
	RST	18H
  ENDIF
	LD	(PLAYSP),SP		;再生中の脱出点
	CALL	RB_INIT
	CALL	PARSE_HDR		;ヘッダ解析(まだIRQ非稼働=直接読み)
  IF PROGRESS
	LD	A,CH_H			;'H' = ヘッダ解析 完了
	RST	18H
  ENDIF
	CALL	RB_PREFILL		;部分プリフィル(起動を速く)
  IF PROGRESS
	LD	A,CH_P			;'P' = プリフィル 完了(先頭はバッファ済み)
	RST	18H
  ENDIF
	CALL	IRQ_SETUP		;ここからISRがSD補充+tickを刻む
  IF PROGRESS
	LD	A,CH_I			;'I' = IRQ設定 完了 → PLAY へ
	RST	18H
  ENDIF
	JP	PLAY
.nf:	LD	HL,MSG_NF
	CALL	PUTS
	RET

;=================================================
;*.VGM一覧表示 (VGMPLAY.asmから流用)
;=================================================
BUILD_LIST:
	LD	HL,MSG_HDR
	CALL	PUTS
	LD	HL,LISTBUF
	LD	B,MAXFILES
	CALL	STRM_DIRLIST
	LD	(FILECNT),A
	XOR	A
	LD	(LISTCNT),A
	LD	A,(FILECNT)
	OR	A
	JR	Z,.done
	LD	HL,LISTBUF
	LD	B,A
.lp:	PUSH	BC
	PUSH	HL
	CALL	IS_VGM
	JR	NZ,.next
	LD	A,(LISTCNT)
	INC	A
	CALL	PRDEC
	LD	HL,MSG_COLON
	CALL	PUTS
	POP	HL
	PUSH	HL
	CALL	PUTS
	LD	A,CR
	RST	18H
	LD	A,LF
	RST	18H
	LD	A,(LISTCNT)
	INC	A
	LD	(LISTCNT),A
.next:	POP	HL
	LD	DE,0DH
	ADD	HL,DE
	POP	BC
	DJNZ	.lp
.done:	LD	HL,MSG_PROMPT
	CALL	PUTS
	RET

GET_NTH_VGM:
	LD	(TARGETK),A
	XOR	A
	LD	(VGMCNT),A
	LD	A,(FILECNT)
	OR	A
	JR	Z,.nf
	LD	HL,LISTBUF
	LD	B,A
.lp:	PUSH	BC
	PUSH	HL
	CALL	IS_VGM
	JR	NZ,.next
	LD	A,(VGMCNT)
	INC	A
	LD	(VGMCNT),A
	LD	HL,TARGETK
	CP	(HL)
	JR	NZ,.next
	POP	HL
	LD	DE,PLAYNAME
	LD	BC,0DH
	LDIR
	POP	BC
	OR	A
	RET
.next:	POP	HL
	LD	DE,0DH
	ADD	HL,DE
	POP	BC
	DJNZ	.lp
.nf:	SCF
	RET

;=================================================
;HL先頭の名前の拡張子が"VGM"ならZ=1。HLは破壊
;=================================================
IS_VGM:
.f:	LD	A,(HL)
	OR	A
	JR	Z,.no
	CP	2EH
	JR	Z,.d
	INC	HL
	JR	.f
.d:	INC	HL
	LD	DE,VGMEXT
	LD	B,3
.c:	LD	A,(DE)
	CP	(HL)
	JR	NZ,.no
	INC	HL
	INC	DE
	DJNZ	.c
	LD	A,(HL)
	OR	A
	RET
.no:	OR	0FFH
	RET

;=================================================
;10進数入力(数字+Enter)。OUT HL=数値(0=終了)
;=================================================
READ_NUM:
	LD	HL,0
.k:	PUSH	HL
	CALL	KEYWAIT
	POP	HL
	CP	CR
	JR	NZ,.chk			;Enter以外は数字判定へ
	LD	A,CR			;Enter:改行してから戻る(再生開始前)
	RST	18H
	LD	A,LF
	RST	18H
	RET
.chk:	CP	30H
	JR	C,.k
	CP	3AH
	JR	NC,.k
	PUSH	AF
	RST	18H
	POP	AF
	SUB	30H
	PUSH	DE
	LD	D,H
	LD	E,L
	ADD	HL,HL
	ADD	HL,HL
	ADD	HL,DE
	ADD	HL,HL
	LD	D,0
	LD	E,A
	ADD	HL,DE
	POP	DE
	JR	.k

;=================================================
;A(0-255)を10進表示(先頭ゼロ抑制)
;=================================================
PRDEC:
	LD	E,A
	LD	D,0
	LD	B,100
	CALL	.pl
	LD	B,10
	CALL	.pl
	LD	A,E
	ADD	A,30H
	RST	18H
	RET
.pl:	LD	C,30H
.s:	LD	A,E
	CP	B
	JR	C,.e
	SUB	B
	LD	E,A
	INC	C
	JR	.s
.e:	LD	A,C
	CP	30H
	JR	NZ,.pr
	LD	A,D
	OR	A
	RET	Z
.pr:	LD	A,C
	RST	18H
	LD	D,1
	RET

PUTS:	LD	A,(HL)
	OR	A
	RET	Z
	RST	18H
	INC	HL
	JR	PUTS

;-------------------------------------------------
IDENT:	DB	"Vgm "			;VGM識別子
TBL9X:	DB	4,4,5,10,1,4		;90H-95Hのオペランド数
MSG_HDR:	DB	CR,LF,"-- VGM (IRQ F-1) --",CR,LF,00H
MSG_COLON:	DB	": ",00H
MSG_PROMPT:	DB	CR,LF,"NO(0=END)? ",00H
VGMEXT:		DB	"VGM"
MSG_NF:		DB	CR,LF,"NOT FOUND",CR,LF,00H
MSG_NOTVGM:	DB	CR,LF,"NOT VGM",CR,LF,00H
MSG_BADHDR:	DB	CR,LF,"BAD HEADER",CR,LF,00H
MSG_BADCMD:	DB	CR,LF,"BAD COMMAND",CR,LF,00H
MSG_END:	DB	CR,LF,"VGM END",CR,LF,00H

;-------------------------------------------------
SAVSP:		DS	2			;SP退避
BLKSZ:		DS	4			;データブロックの残りサイズ
RBUF:		DS	RBUF_SIZE		;先読みリングバッファ
RBUF_END	EQU	$			;バッファ末尾+1
RB_RDP:		DS	2			;読み出しポインタ(消費者=メイン)
RB_WRP:		DS	2			;書き込みポインタ(生産者=ISR)
RB_CNT:		DS	2			;バッファ内バイト数(0..RBUF_SIZE)
RB_EOF:		DS	1			;先読みが終端に達したら0以外
PLAYSP:		DS	2			;再生中の脱出点SP
LISTCNT:	DS	1			;一覧の件数
VGMCNT:		DS	1			;VGM計数(選択用)
TARGETK:	DS	1			;選択された番号(1始まり)
OPNREG:		DS	1			;YM2203レジスタ番号 一時
OPNDAT:		DS	1			;YM2203データ 一時
FILECNT:	DS	1			;全ファイル件数
LISTBUF:	DS	MAXFILES*0DH		;一覧バッファ(1件13バイト)
PLAYNAME:	DS	0DH			;選択ファイル名

;--- 割り込み関連 ---
IVT_PTR:	DS	2			;$8000 + (IVR_FMTAV) をキャッシュ
SAVED_VEC_FMTA:	DS	2			;元のベクタエントリ(2バイト)
TA_TICKS:	DS	1			;ISRが進めるtickカウンタ(8bit、wrap可)
TA_CTRL_SHADOW:	DS	1			;27Hに書いた制御バイト
TA_NA:		DS	2			;Timer A プリロード値(ISRが毎tick再ロード)
WCREDIT:	DS	2			;待ちオーバーシュートの繰越サンプル
IRQ_ACTIVE:	DS	1			;1=ISR稼働中(RB_GET/GETBの排他切替)
GETB_TO:	DS	2			;GETB空スピンのタイムアウト計数(PROGRESS用)

;ISRが割り込み中にコード中最も深い STRM_READ(セクタ/クラスタ跨ぎで MMC_BRD_CMD/
;READ_FAT がさらに再帰)をメインのスタック上にネストするため、VGMPLAY(256)より
;厚く確保する。STACK_TOP は VGMPLAY 実績の E12EH より下に収まる。
STACK:		DS	512			;プレイヤー専用スタック(ISRネスト分を上乗せ)
STACK_TOP	EQU	$			;スタック先頭(SPの初期値)

	END
