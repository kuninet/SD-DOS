;=================================================
;VGMIRQS - VGM再生(VGMPLAYベース、SD補充だけ割り込みに移した版)
;=================================================
;・設計: 動いている VGMPLAY のコードをほぼそのまま使い、wait の刻み方
;  (WAIT_KV の busy-loop)は一切変えない。唯一の変更は「SD の先読み補充を
;  WAIT_DE 内の同期処理から Timer A 割り込み(背景)へ移した」こと。
;・狙い: テンポは VGMPLAY の busy-loop のまま(実機で実績あり)。Timer A 割り込みは
;  バッファ補充だけを担い、その周期精度はテンポに影響しない。よってタイマが多少
;  乱れても音が崩れない(tick を数えてテンポにする VGMIRQF=F-1 の弱点を回避)。
;・ISR は「Timer A 再起動(stop→load→start で割り込み再武装)+ RB_TRYFILL1」だけ。
;  SD/STRM 状態は ISR だけが触る。リングバッファは ISR=生産者/メイン=消費者で
;  共有するので消費側 RB_GET を IRQ 稼働中のみ DI/EI で排他する。
;・I=80H のまま $8000台RAM の IM2 ベクタを使い、空き1本だけ自前ISRに差し替える
;  (VGMIRQ と同じ。232C/8251 エントリには触れずシリアル受信と共存)。
;・使い方: LOAD "VGMIRQS.CMT" →(必要ならCD)→ モニタで G9000
;・POKE: 9003H=WAIT_KV(テンポ) 9004H=IVR_FMTAV(vector番号)
;        9005H=WRITE_COST(書込補正) 9006H=SPTV(Timer周期/補充レート)
;        9007H/9008H=TPSV_LO/HI(NA校正) 9009H=FILL_PER_TICKV(補充/tick)
;        900AH=BUSY_MAX(BUSY待ち上限)
;・進行状況表示(PROGRESS=1): O=OPEN H=ヘッダ P=プリフィル I=IRQ設定、
;  U=バッファ枯渇(ISRが補充できていない=Timer A未発火の疑い)
;・ヘッダ=header.md コマンド=commands.md 音源=sound-io.md (docs/vgm/)
;=================================================

STRM_OPEN	EQU	6005H		;ストリームを開く
STRM_READ	EQU	6008H		;１バイト取得
STRM_CLOSE	EQU	600BH		;ストリームを閉じる
OPN_ADDR	EQU	80H		;YM2203 レジスタ番号/ステータス
OPN_DATA	EQU	81H		;YM2203 データ
PSG_ADDR	EQU	0A0H		;PSG#1 レジスタ番号
PSG_DATA	EQU	0A1H		;PSG#1 データ
WAIT_K	EQU	02H		;1サンプルの内側ループ回数(実機調整値)。POKE &H9003
WRITE_COST	EQU	23H		;音源書き込み1回の処理時間(サンプル換算)。POKE &H9005
CR	EQU	0DH		;
LF	EQU	0AH		;
BASIC	EQU	0081H		;BASICへ復帰(モニタGや自動実行どちらでも安全)
KEYWAIT	EQU	0F75H		;1文字入力待ち A<-コード
STRM_DIRLIST	EQU	600EH		;ディレクトリ列挙(全ファイル名を一括取得)
MAXFILES	EQU	40H		;一覧の最大ファイル数(64)
BUSY_MAX	EQU	00H		;YM2203 BUSY待ち上限(0=無制限)。POKE &H900A
;先読みリングバッファは N-BASIC 高位ワーク(EDCE で衝突)の手前まで極限まで大きく取る。
;バッファ末尾の後ろに置く作業変数+スタック(約1.5KB)を足した最上位が EDCE を超えない
;ようにする。下の RBUF_SIZE で STACK_TOP ≒ EB00 台(EDCE まで約0.7KB余裕)。
RBUF_SIZE	EQU	5000H		;先読みリングバッファ(20KB)。密なところの貯金を最大化
INITFILL	EQU	3000H		;起動時の部分プリフィル(12KB)。出だしの貯金も厚めに

;--- YM2203 Timer A(背景SD補充のトリガにのみ使用)---
TA_REG_HI	EQU	24H
TA_REG_LO	EQU	25H
TA_REG_CTRL	EQU	27H
TA_CTRL_RUN_IRQEN	EQU	00000101B	;LoadA=1, IRQEN A=1
TA_CTRL_STOP_RESET	EQU	00010000B	;ResetA=1, LoadA=0
TICKS_PER_SAMPLE_X256	EQU	289		;1tickあたりサンプル換算(NA計算用)
IVT_PAGE	EQU	80H		;Iレジスタ値(=IM2テーブルページ)
IVR_FMTA_DEFAULT	EQU	04H	;INT4..7のうちFM Timer A用vector(実機で要確認)
SAMPLES_PER_TICK	EQU	80	;Timer A周期(サンプル)≒補充間隔。精度はテンポ無関係
FILL_PER_TICK	EQU	01H		;1tickあたりのSD補充バイト数
FILL_MINSAMP	EQU	40H		;この値(サンプル)未満の短い待ちではSDを読まない(音符飛び防止)

;--- 進行状況表示(実機デバッグ用。RST 18Hで1文字)---
PROGRESS	EQU	1
CH_O	EQU	4FH		;'O'=OPEN成功
CH_H	EQU	48H		;'H'=ヘッダ解析
CH_P	EQU	50H		;'P'=プリフィル
CH_I	EQU	49H		;'I'=IRQ設定→PLAY
CH_U	EQU	55H		;'U'=バッファ枯渇(ISRが補充できていない)

	ORG	09000H

	JP	START			;9000H 実行エントリ(モニタG9000)
WAIT_KV:	DB	WAIT_K		;9003H ウェイト係数(テンポ)。POKE &H9003,n
IVR_FMTAV:	DB	IVR_FMTA_DEFAULT	;9004H FM Timer A IRQ vector番号
WRITE_COSTV:	DB	WRITE_COST	;9005H 書込処理コスト補正(WDEBT)
SPTV:		DB	SAMPLES_PER_TICK	;9006H Timer A周期(サンプル)=補充間隔
TPSV_LO:	DB	33		;9007H NA校正 下位(=33で289)
TPSV_HI:	DB	1		;9008H NA校正 上位(=1で+256)
FILL_PER_TICKV:	DB	FILL_PER_TICK	;9009H 1tickあたり補充バイト数
BUSY_MAXV:	DB	BUSY_MAX		;900AH BUSY待ち上限(0=無制限)
READ_SAMPV:	DB	30H		;900BH SD読み1バイトの所要(サンプル換算)。ISRの
					;     SD補充時間をwaitから精算してテンポを保つ。大=速くなる
					;     (sim既定0x30でVGMPLAY同等。実機はBUSY待ち分もう少し上げる)
FILL_MINSAMPV:	DB	FILL_MINSAMP	;900CH この値未満の短い待ちではSDを読まない。
					;     音符が飛ぶなら上げる(短い待ちでの読みを抑える)

START:
	DI				;ベクタ差し替え前。IRQ_SETUPでEIする
	LD	(SAVSP),SP		;BASIC復帰用にSP保存
	LD	SP,STACK_TOP		;専用スタックへ
	XOR	A
	LD	(IRQ_ACTIVE),A		;割り込み稼働フラグ=0
	EI				;メニュー中はN-BASIC割り込みを止めない(KEYWAIT用)
MENU:
	CALL	BUILD_LIST		;*.VGM一覧表示、(LISTCNT)=件数
	LD	A,(LISTCNT)		;0件なら終了
	OR	A
	JP	Z,BASIC
	CALL	READ_NUM		;HL=入力番号(1始まり、0/Enterで終了)
	LD	A,H			;256以上は無効→再表示
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
	CALL	PLAY_FILE		;再生(終わるとここへ戻る)
	JR	MENU

;-------------------------------------------------
;正常終了（再生終了・EOF）
;-------------------------------------------------
DONE:
	LD	SP,(PLAYSP)		;再生中の脱出点へ
	CALL	IRQ_TEARDOWN		;Timer A停止・ベクタ復元
	CALL	STRM_CLOSE
  IF PROGRESS
	LD	HL,(ISR_CNT)		;診断: ISRが発火したか(J=発火 K=未発火)+回数の上位
	LD	A,H
	OR	L
	LD	A,4BH			;'K'=ISR未発火(割り込みが来ていない)
	JR	Z,.kj
	LD	A,4AH			;'J'=ISR発火あり
.kj:	RST	18H
	LD	A,(ISR_CNT+1)		;発火回数の上位バイト(≒回数/256)を10進表示
	CALL	PRDEC
  ENDIF
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
	CALL	IRQ_TEARDOWN		;Timer A停止・ベクタ復元
	CALL	STRM_CLOSE
	POP	HL
	CALL	PUTS
	RET				;メニューへ戻る

;-------------------------------------------------
;ヘッダ解析（docs/vgm/header.md の最小解析範囲）
;・識別子を確認し、バージョンからデータ開始位置を求めて読み進める
;-------------------------------------------------
PARSE_HDR:
	LD	HL,IDENT		;識別子 "Vgm " の確認
	LD	B,4			;
.ID:	CALL	GETB			;
	CP	(HL)			;
	JR	NZ,.NOTVGM		;
	INC	HL			;
	DJNZ	.ID			;
	LD	DE,4			;04H-07H（EOFオフセット）を読み捨てる
	CALL	SKIP			;
	CALL	GETB			;08H- バージョン（BCD）下位ワード
	LD	C,A			;
	CALL	GETB			;
	LD	B,A			;BC=バージョン下位ワード
	CALL	GETB			;上位2バイトは読み捨てる
	CALL	GETB			;
	LD	H,B			;バージョン1.50未満なら旧形式
	LD	L,C			;
	LD	DE,0150H		;
	OR	A			;
	SBC	HL,DE			;
	JR	C,.OLD			;
	LD	DE,0028H		;0CH-33Hを読み捨てる
	CALL	SKIP			;
	CALL	GETB			;34H- データ開始オフセット（34Hからの相対）
	LD	E,A			;
	CALL	GETB			;
	LD	D,A			;DE=オフセット下位ワード
	CALL	GETB			;上位2バイトが0以外なら異常
	LD	C,A			;
	CALL	GETB			;
	OR	C			;
	JR	NZ,.BADHDR		;
	EX	DE,HL			;残り読み捨て数=オフセット-4（38Hまで読み済み）
	LD	DE,4			;
	OR	A			;
	SBC	HL,DE			;
	JR	C,.BADHDR		;オフセットが4未満なら異常
	EX	DE,HL			;
	JP	SKIP			;データ開始位置まで読み捨てて戻る

.OLD:	LD	DE,0034H		;旧形式はデータ開始40H固定。0CH-3FHを読み捨てる
	JP	SKIP			;

.NOTVGM:
	LD	HL,MSG_NOTVGM		;
	JP	ABORT			;
.BADHDR:
	LD	HL,MSG_BADHDR		;
	JP	ABORT			;

;-------------------------------------------------
;再生ループ（docs/vgm/commands.md のコマンド表）
;-------------------------------------------------
PLAY:
.LOOP:	CALL	GETB			;コマンド取得
	CP	66H			;終了コマンド
	JP	Z,DONE			;
	CP	55H			;YM2203書き込み
	JR	Z,.OPN			;
	CP	0A0H			;PSG書き込み
	JR	Z,.PSG			;
	CP	61H			;ウェイト（サンプル数指定）
	JR	Z,.W61			;
	CP	62H			;ウェイト（735サンプル）
	JR	Z,.W62			;
	CP	63H			;ウェイト（882サンプル）
	JR	Z,.W63			;
	LD	C,A			;C<-コマンド退避
	AND	0F0H			;
	CP	70H			;70H-7FH:短いウェイト
	JR	Z,.W7X			;
	CP	80H			;80H-8FH:YM2612 DAC+ウェイト
	JR	Z,.LOOP			;対象チップがないため無視する
	LD	A,C			;
	JP	SKIP_CMD		;その他は読み飛ばし規則へ

.OPN:	CALL	GETB			;レジスタ番号
	LD	(OPNREG),A		;
	CALL	GETB			;データ値
	LD	(OPNDAT),A		;
	LD	A,(BUSY_MAXV)		;BUSY待ち上限(0=無制限)
	LD	B,A			;
.BUSY:	IN	A,(OPN_ADDR)		;BUSY(bit7)が下がるまで
	RLCA				;
	JR	NC,.BWOK		;下がった
	LD	A,B			;上限0なら無制限
	OR	A			;
	JR	Z,.BUSY			;
	DJNZ	.BUSY			;上限まで待って打ち切り
.BWOK:	DI				;2段書き(80H→81H)の間にISRが27Hを書くとラッチが壊れる
	LD	A,(OPNREG)		;レジスタ番号を出力
	OUT	(OPN_ADDR),A		;
	LD	A,(OPNREG)		;レジスタ選択後の短い待ち(ダミー読み)
	LD	A,(OPNDAT)		;データ値を出力
	OUT	(OPN_DATA),A		;
	EI				;
	CALL	ADD_DEBT		;処理時間debtを加算
	JP	PLAY.LOOP		;

.PSG:	CALL	GETB			;レジスタ番号を出力
	OUT	(PSG_ADDR),A		;
	CALL	GETB			;データ値を出力
	OUT	(PSG_DATA),A		;
	CALL	ADD_DEBT			;処理時間debtを加算
	JP	PLAY.LOOP			;

.W61:	CALL	GETB			;DE<-サンプル数
	LD	E,A			;
	CALL	GETB			;
	LD	D,A			;
	CALL	WAIT_DE			;
	JP	PLAY.LOOP			;
.W62:	LD	DE,735			;1/60秒
	CALL	WAIT_DE			;
	JP	PLAY.LOOP			;
.W63:	LD	DE,882			;1/50秒
	CALL	WAIT_DE			;
	JP	PLAY.LOOP			;
.W7X:	LD	A,C			;（下位4ビット+1）サンプル
	AND	0FH			;
	INC	A			;
	LD	E,A			;
	LD	D,0			;
	CALL	WAIT_DE			;
	JP	PLAY.LOOP			;

;-------------------------------------------------
;未対応コマンドの読み飛ばし（docs/vgm/commands.md の規則）
;IN  A=コマンド
;-------------------------------------------------
SKIP_CMD:
	CP	30H			;00H-2FH:未知
	JR	C,.BAD			;
	CP	40H			;30H-3FH:1バイト
	JR	C,.S1			;
	CP	4FH			;40H-4EH:未知
	JR	C,.BAD			;
	CP	51H			;4FH,50H:1バイト
	JR	C,.S1			;
	CP	60H			;51H-5FH:2バイト
	JR	C,.S2			;
	CP	64H			;64H:3バイト
	JR	Z,.S3			;
	CP	67H			;67H:データブロック
	JR	Z,.BLK			;
	CP	90H			;60H,65H,68H-6FH:未知
	JR	C,.BAD			;
	CP	96H			;90H-95H:DACストリーム
	JR	C,.S9X			;
	CP	0A1H			;96H-0A0H:未知
	JR	C,.BAD			;
	CP	0C0H			;0A1H-0BFH:2バイト
	JR	C,.S2			;
	CP	0E0H			;0C0H-0DFH:3バイト
	JR	C,.S3			;
.S4:	CALL	GETB			;0E0H-0FFH:4バイト
.S3:	CALL	GETB			;
.S2:	CALL	GETB			;
.S1:	CALL	GETB			;
	JP	PLAY.LOOP		;

.BAD:	LD	HL,MSG_BADCMD		;未知のコマンドは解釈が崩れているため停止
	JP	ABORT			;

.S9X:	SUB	90H			;90H-95Hのオペランド長を表から引く
	LD	HL,TBL9X		;
	LD	E,A			;
	LD	D,0			;
	ADD	HL,DE			;
	LD	B,(HL)			;
.S9L:	CALL	GETB			;
	DJNZ	.S9L			;
	JP	PLAY.LOOP		;

.BLK:	CALL	GETB			;66H（互換用バイト）
	CALL	GETB			;ブロックタイプ
	LD	HL,BLKSZ		;サイズ4バイト（リトルエンディアン）
	LD	B,4			;
.BSZ:	CALL	GETB			;
	LD	(HL),A			;
	INC	HL			;
	DJNZ	.BSZ			;
.BSKIP:	LD	HL,BLKSZ		;サイズが0になるまで読み捨てる
	LD	B,4			;
	XOR	A			;
.BZ:	OR	(HL)			;
	INC	HL			;
	DJNZ	.BZ			;
	OR	A			;
	JP	Z,PLAY.LOOP		;
	LD	HL,BLKSZ		;サイズを1減らす（4バイトの桁借り伝播）
	LD	A,(HL)			;
	SUB	1			;
	LD	(HL),A			;
	JR	NC,.BRD			;
	LD	B,3			;
.BD:	INC	HL			;
	LD	A,(HL)			;
	SBC	A,0			;
	LD	(HL),A			;
	JR	NC,.BRD			;
	DJNZ	.BD			;
.BRD:	CALL	GETB			;
	JR	.BSKIP			;

;-------------------------------------------------
;指定バイト数の読み捨て
;IN  DE=バイト数
;-------------------------------------------------
SKIP:	LD	A,D			;
	OR	E			;
	RET	Z			;
	CALL	GETB			;
	DEC	DE			;
	JR	SKIP			;

;-------------------------------------------------
;１バイト取得（EOFは再生終了として扱う）
;OUT A=取得した値
;-------------------------------------------------
GETB:	PUSH	HL			;HL/DE/BCを保存（呼び出し側がHL等を使う）
	PUSH	DE			;
	PUSH	BC			;
	CALL	RB_GET_SAFE		;リングバッファから取得
	JR	NC,.GOT			;取得できた
	LD	A,(RB_EOF)		;バッファ空。先読みが終端に達していれば
	OR	A			;
	JR	NZ,.EOF			;再生終了へ
	;バッファ空(密なところでISRの補充が間に合わなかった)→同期で直接読む。
	;GETBはタイマOFF(待ち以外)のときだけ呼ばれるのでISRと衝突しない=再入安全。
	;VGMPLAYと同じく、密なところは引っかかりつつも止まらず読み切る。
	CALL	STRM_READ		;
	JR	C,.RDEOF		;
.GOT:	POP	BC			;
	POP	DE			;
	POP	HL			;
	RET				;A=取得した値
.RDEOF:	LD	A,0FFH			;直接読みでEOF
	LD	(RB_EOF),A		;
.EOF:	POP	BC			;
	POP	DE			;
	POP	HL			;
	JP	DONE			;EOFは再生終了として扱う

;-------------------------------------------------
;サンプル数ぶんのウェイト
;IN  DE=サンプル数
;-------------------------------------------------
WAIT_DE:
;SDの読みは「長い待ちの間だけ」ISRにやらせる。短い待ち/OPNバースト中に444μsのSD読みが
;入ると、その間OPN書込みが止まって音符が飛ぶため(VGMPLAYと同じ戦略)。長い待ちのとき
;だけTimer Aを起動し、待ちの終わりで停止する。短い待ちの間はタイマOFF=ISR非発火で
;まったく邪魔をしない。busy-loopの音価(テンポ)は不変。
	;ISRが長い待ち中に貯めたSD精算(SD_DEBT)をWDEBTへ移す(DIで保護)
	DI
	PUSH	DE			;入力サンプル数を保護
	LD	HL,(SD_DEBT)
	LD	DE,(WDEBT)
	ADD	HL,DE
	LD	(WDEBT),HL
	LD	HL,0
	LD	(SD_DEBT),HL
	POP	DE
	EI
	;処理時間debt(音源書込み+SD精算)を先に差し引く
	PUSH	DE			;元ウェイトを退避
	LD	HL,(WDEBT)		;DE = ウェイト - WDEBT
	LD	A,E
	SUB	L
	LD	E,A
	LD	A,D
	SBC	A,H
	LD	D,A
	JR	C,.DEBTOVER		;WDEBT>ウェイト:全部debtで消化
	POP	HL			;退避ウェイト破棄(DE=残りウェイト)
	LD	HL,0			;debt完済
	LD	(WDEBT),HL
	;この待ちが長い(>=FILL_MINSAMP)ならTimer A起動、短ければ起動しない
	XOR	A
	LD	(SD_ARMED),A		;既定:起動せず
	LD	A,D			;DE>=256 は無条件で長い
	OR	A
	JR	NZ,.arm
	LD	A,(FILL_MINSAMPV)	;FILL_MINSAMP >= E なら短い→起動せず
	CP	E
	JR	NC,.BURN
.arm:	DI				;長い: この待ちの間だけISRがSDを読む
	CALL	TA_REARM
	EI
	LD	A,1
	LD	(SD_ARMED),A
.BURN:	LD	A,D			;残ウェイト=0なら終了処理
	OR	E
	JR	NZ,.cont
	LD	A,(SD_ARMED)		;起動していたらTimer A停止(次のバーストでISR発火させない)
	OR	A
	RET	Z
	DI
	CALL	TA_STOP
	EI
	RET
.cont:	LD	A,(WAIT_KV)		;空ループでウェイトを消化
	LD	B,A
.W:	DJNZ	.W
	DEC	DE
	JR	.BURN
.DEBTOVER:
	LD	HL,(WDEBT)		;新WDEBT = WDEBT - 元ウェイト
	POP	DE			;DE=元ウェイト
	OR	A			;CY=0
	SBC	HL,DE
	LD	(WDEBT),HL
	RET				;ウェイトはdebtで完済(短すぎ→SDも読まない)


;-------------------------------------------------
;先読みリングバッファ（SD読み込み遅延をウェイト中に隠す）
;-------------------------------------------------
;[RB]初期化
;-------------------------------------------------
;処理時間debtにWRITE_COSTを加算(音源書き込み1回分)
;-------------------------------------------------
ADD_DEBT:
	PUSH	HL			;
	PUSH	BC			;
	LD	HL,(WDEBT)		;
	LD	A,(WRITE_COSTV)		;
	LD	C,A			;
	LD	B,0			;
	ADD	HL,BC			;
	LD	(WDEBT),HL		;
	POP	BC			;
	POP	HL			;
	RET				;

RB_INIT:
	LD	HL,RBUF			;
	LD	(RB_RDP),HL		;読み書きポインタを先頭へ
	LD	(RB_WRP),HL		;
	LD	HL,0			;
	LD	(RB_CNT),HL		;バイト数=0
	LD	(WDEBT),HL		;処理時間debt=0
	LD	(SD_DEBT),HL		;SD精算debt=0
	XOR	A			;
	LD	(RB_EOF),A		;終端フラグ=0
	RET				;

;[RB]1バイト格納（満タンでないこと） IN A=値
RB_PUT:
	PUSH	HL			;
	PUSH	DE			;
	LD	HL,(RB_WRP)		;
	LD	(HL),A			;格納
	INC	HL			;
	LD	DE,RBUF_END		;末尾なら先頭へラップ
	LD	A,H			;
	CP	D			;
	JR	NZ,.NW			;
	LD	A,L			;
	CP	E			;
	JR	NZ,.NW			;
	LD	HL,RBUF			;
.NW:	LD	(RB_WRP),HL		;
	LD	HL,(RB_CNT)		;バイト数++
	INC	HL			;
	LD	(RB_CNT),HL		;
	POP	DE			;
	POP	HL			;
	RET				;

;[RB]1バイト取得 OUT A=値,CY=0 / CY=1:空
;！BC/DE/HLを壊す（呼び出し側GETBが保存している）
RB_GET:
	LD	HL,(RB_CNT)		;
	LD	A,H			;
	OR	L			;
	SCF				;空ならCY=1
	RET	Z			;
	LD	HL,(RB_RDP)		;
	LD	B,(HL)			;値→B
	INC	HL			;
	LD	DE,RBUF_END		;末尾なら先頭へラップ
	LD	A,H			;
	CP	D			;
	JR	NZ,.NW			;
	LD	A,L			;
	CP	E			;
	JR	NZ,.NW			;
	LD	HL,RBUF			;
.NW:	LD	(RB_RDP),HL		;
	LD	HL,(RB_CNT)		;バイト数--
	DEC	HL			;
	LD	(RB_CNT),HL		;
	LD	A,B			;値→A
	OR	A			;CY=0
	RET				;

;[RB]RB_GETの排他ラッパ(メイン消費者専用)
;・IRQ稼働中はISR(RB_PUT)とRB_CNT更新が競合するためDI/EIで囲う。ISRは割り込み
;  禁止状態で走るので生産側は原子的、消費側だけ保護すればよい。
;・非稼働中(IRQ_ACTIVE=0)はそのままRB_GET。OUT A=値,CY=0 / CY=1:空。破壊AF,BC,DE,HL
RB_GET_SAFE:
	LD	A,(IRQ_ACTIVE)		;
	OR	A			;
	JP	Z,RB_GET		;非稼働中はそのまま
	DI				;
	CALL	RB_GET			;
	EI				;
	RET				;

;[RB]空き時間にバッファを満タンまで先読みする
RB_REFILL:
	LD	A,(RB_EOF)		;既に終端なら何もしない
	OR	A			;
	RET	NZ			;
	PUSH	BC			;
	PUSH	DE			;DEはWAIT_DEのサンプル数。保存必須
	PUSH	HL			;
.R:	LD	HL,(RB_CNT)		;CNT>=RBUF_SIZE なら満タン
	LD	DE,RBUF_SIZE		;
	OR	A			;CY=0
	SBC	HL,DE			;
	JR	NC,.FULL		;
	CALL	STRM_READ		;1バイト先読み
	JR	C,.EOF			;CY=1:終端
	CALL	RB_PUT			;バッファへ
	JR	.R			;
.EOF:	LD	A,0FFH			;終端フラグを立てる
	LD	(RB_EOF),A		;
.FULL:	POP	HL			;
	POP	DE			;
	POP	BC			;
	RET				;

;[RB]満タンでなければ1バイトだけ先読み OUT CY=1:読んで格納 / CY=0:満タンorEOF

;[RB]起動時の部分プリフィル(INITFILLバイトまで先読み。残りは再生中に育てる)
RB_PREFILL:
.pf:	CALL	RB_TRYFILL1		;1バイト先読み(CY=1で読んだ)
	JR	NC,.done		;満タン/EOF
	LD	HL,(RB_CNT)		;CNT>=INITFILLなら打ち切り
	LD	DE,INITFILL
	OR	A
	SBC	HL,DE
	JR	C,.pf			;まだ→続行
.done:	RET
RB_TRYFILL1:
	LD	A,(RB_EOF)		;既に終端なら何もしない
	OR	A			;
	JR	NZ,.NO			;
	PUSH	HL			;
	PUSH	DE			;
	LD	HL,(RB_CNT)		;CNT>=RBUF_SIZE なら満タン
	LD	DE,RBUF_SIZE		;
	OR	A			;CY=0
	SBC	HL,DE			;
	POP	DE			;
	POP	HL			;
	JR	NC,.NO			;満タン
	CALL	STRM_READ		;1バイト読む(BC/DE/HL/IX保存)
	JR	C,.EOF			;CY=1:終端
	CALL	RB_PUT			;バッファへ(HL/DE保存)
	SCF				;CY=1:読んだ
	RET				;
.EOF:	LD	A,0FFH			;終端フラグを立てる
	LD	(RB_EOF),A		;
.NO:	OR	A			;CY=0
	RET				;

;-------------------------------------------------
;00H終端文字列の表示
;IN  HL=文字列の先頭アドレス
;-------------------------------------------------
;=================================================
;再生(1ファイル): PLAYNAMEを開いて再生、終わるとRETでメニューへ
;=================================================
PLAY_FILE:
	LD	HL,PLAYNAME
	CALL	STRM_OPEN
	JR	C,.nf
  IF PROGRESS
	LD	A,CH_O			;'O'=OPEN成功
	RST	18H
  ENDIF
	LD	(PLAYSP),SP		;再生中の脱出点(DONE/ABORTがここへ戻す)
	CALL	RB_INIT
	CALL	PARSE_HDR
  IF PROGRESS
	LD	A,CH_H			;'H'=ヘッダ解析
	RST	18H
  ENDIF
	CALL	RB_PREFILL		;部分プリフィル(起動を速く。まだISR非稼働=メインが直読)
  IF PROGRESS
	LD	A,CH_P			;'P'=プリフィル(先頭はバッファ済み)
	RST	18H
  ENDIF
	CALL	IRQ_SETUP		;ここからISRが背景でSD補充する
  IF PROGRESS
	LD	A,CH_I			;'I'=IRQ設定→PLAY
	RST	18H
  ENDIF
	JP	PLAY
.nf:	LD	HL,MSG_NF
	CALL	PUTS
	RET

;=================================================
;*.VGM一覧表示。(LISTCNT)=件数。番号は1始まり
;=================================================
;*.VGM一覧表示。1回のSTRM_DIRLISTで全名取得しメモリ上で処理
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

;=================================================
;K番目(1始まり)の.VGMをPLAYNAMEへ(メモリ上LISTBUF走査)
;IN A=K OUT CY=0成功/CY=1なし
;=================================================
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
;HL先頭の名前の拡張子が"VGM"ならZ=1。HL破壊
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
.chk:	
	CP	30H
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

PUTS:	LD	A,(HL)			;
	OR	A			;
	RET	Z			;
	RST	18H			;
	INC	HL			;
	JR	PUTS			;

;=================================================
;Timer A 割り込み(背景SD補充)関連
;=================================================
;OPN_WR_RD - YM2203 1レジスタ書込み(BUSY待ちあり)。IN D=reg,E=data 破壊AFのみ
OPN_WR_RD:
	PUSH	AF
.busy:	IN	A,(OPN_ADDR)
	RLCA
	JR	C,.busy
	LD	A,D
	OUT	(OPN_ADDR),A
	LD	A,D			;ダミーで短い待ち
	LD	A,E
	OUT	(OPN_DATA),A
	POP	AF
	RET

;TA_LOAD_HL - 24H/25HへTimer A 10bitプリロード書込み。IN HL=NA(0..1023) 破壊AFのみ
TA_LOAD_HL:
	PUSH	BC
	PUSH	DE
	PUSH	HL
	PUSH	AF
	LD	C,L			;低位を退避
	SRL	H			;高位=HL>>2
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

;TA_START - 27H<-LoadA|IRQEN(起動)。破壊AFのみ
TA_START:
	PUSH	DE
	LD	D,TA_REG_CTRL
	LD	E,TA_CTRL_RUN_IRQEN
	CALL	OPN_WR_RD
	POP	DE
	RET

;TA_STOP - 27H<-ResetA(停止+flag消去)。破壊AFのみ
TA_STOP:
	PUSH	DE
	LD	D,TA_REG_CTRL
	LD	E,TA_CTRL_STOP_RESET
	CALL	OPN_WR_RD
	LD	D,TA_REG_CTRL		;resetパルスを戻して通常停止状態へ
	LD	E,0
	CALL	OPN_WR_RD
	POP	DE
	RET

;MUL_DE_TPS - HL=(DE*TPS)>>8 (TPSV_HI=1前提 → HL=DE+(DE*TPSV_LO)>>8)。IN DE 破壊AF,BC DE保存
MUL_DE_TPS:
	PUSH	BC
	PUSH	DE
	LD	A,(TPSV_LO)
	LD	C,A
	LD	HL,0
	XOR	A
	LD	B,8
.lp:	ADD	HL,HL
	ADC	A,A
	SLA	C
	JR	NC,.skip
	ADD	HL,DE
	ADC	A,0
.skip:	DJNZ	.lp
	LD	L,H
	LD	H,A
	POP	DE
	ADD	HL,DE
	POP	BC
	RET

;CALC_TA_NA - OUT HL=NA=1024-(SPTV*TPS/256)、1..1023にクランプ。破壊AF,BC,DE,HL
CALC_TA_NA:
	LD	A,(SPTV)
	LD	E,A
	LD	D,0
	CALL	MUL_DE_TPS		;HL=tick数(DE保存)
	EX	DE,HL			;DE=tick数
	LD	HL,1024
	OR	A
	SBC	HL,DE			;HL=NA
	LD	A,H
	OR	L
	RET	NZ
	LD	HL,1
	RET

;TA_REARM - 背景タイマを停止→NA再ロード→起動して割り込みを再武装する
;・VGMデータが27Hを書くと背景タイマが止まる(LoadA=0)。これを各WAIT_DEの先頭と
;  ISR内で呼び、タイマを生かし続ける(VGMIRQと同じ「毎回再起動」方式)。
; 破壊: AF,BC,DE,HL (呼び出し側で保護すること)
TA_REARM:
	CALL	TA_STOP
	LD	HL,(TA_NA)
	CALL	TA_LOAD_HL
	CALL	TA_START
	RET

;IRQ_SETUP - ベクタ退避→自前ISR設置→Timer A起動(以後ISRが毎tick再起動)→EI
IRQ_SETUP:
	DI
	LD	A,(IVR_FMTAV)		;HL=$8000+(IVR_FMTAV)
	LD	L,A
	LD	H,IVT_PAGE
	LD	(IVT_PTR),HL
	LD	E,(HL)			;既存エントリ退避
	INC	HL
	LD	D,(HL)
	LD	(SAVED_VEC_FMTA),DE
	LD	HL,(IVT_PTR)		;自前ハンドラを書く
	LD	DE,ISR_FMTA
	LD	(HL),E
	INC	HL
	LD	(HL),D
	LD	A,IVT_PAGE		;I=80H, IM2
	LD	I,A
	IM	2
  IF PROGRESS
	LD	HL,0			;ISR発火カウンタ初期化(診断用)
	LD	(ISR_CNT),HL
  ENDIF
	CALL	CALC_TA_NA		;HL=NA
	LD	(TA_NA),HL		;WAIT_DE/ISRが再ロードするため保存
	CALL	TA_STOP			;初期は停止(タイマは長い待ちのときだけWAIT_DEが起動)
	LD	A,0FFH			;割り込み稼働フラグON
	LD	(IRQ_ACTIVE),A
	EI
	RET

;IRQ_TEARDOWN - Timer A停止→ベクタ復元→IM1→EI
IRQ_TEARDOWN:
	DI
	XOR	A
	LD	(IRQ_ACTIVE),A		;先にフラグを下げる
	CALL	TA_STOP
	LD	HL,(IVT_PTR)		;ベクタ復元
	LD	DE,(SAVED_VEC_FMTA)
	LD	(HL),E
	INC	HL
	LD	(HL),D
	IM	1
	EI
	RET

;ISR_FMTA - Timer A 割り込み: タイマ再起動(再武装)+ SD補充だけ。tick等の演奏処理はしない
;・連続モードでflagリセットのみだと実機で2発目以降のIRQエッジが出ないため、毎回
;  TA_STOP→TA_LOAD→TA_STARTで再起動する(VGMIRQと同じ実績ある方式)。
;・STRM_READがBC/DE/HLを使うのでEX AF,AF'+EXXで退避(IXはSTRM_READが自前退避)。
ISR_FMTA:
	EX	AF,AF'
	EXX
  IF PROGRESS
	LD	HL,(ISR_CNT)		;ISR発火回数++(診断: 終了時にDONEで表示)
	INC	HL
	LD	(ISR_CNT),HL
  ENDIF
	CALL	TA_REARM		;停止→NA再ロード→再起動(次のオーバーフローを再武装)
	LD	A,(FILL_PER_TICKV)	;SD補充: FILL_PER_TICKVバイトまで
	OR	A
	JR	Z,.done
	LD	B,A
.fl:	CALL	RB_TRYFILL1		;満タン/EOFでなければ1バイト補充
	JR	NC,.done
	;読んだ1バイト分の所要(READ_SAMP)をSD_DEBTへ積む(WAIT_DEがWDEBTへ移して精算)
	PUSH	BC			;ループ counter 退避
	LD	HL,(SD_DEBT)
	LD	A,(READ_SAMPV)
	LD	C,A
	LD	B,0
	ADD	HL,BC
	LD	(SD_DEBT),HL
	POP	BC
	DJNZ	.fl
.done:	EXX
	EX	AF,AF'
	EI
	RETI

IDENT:	DB	"Vgm "			;VGM識別子
TBL9X:	DB	4,4,5,10,1,4		;90H-95Hのオペランド長
FNAME:	DB	"/MUSIC.VGM",00H	;対象のファイル名（00H終端）
MSG_HDR:	DB	CR,LF,"-- VGM --",CR,LF,00H
MSG_COLON:	DB	": ",00H
MSG_PROMPT:	DB	CR,LF,"NO(0=END)? ",00H
VGMEXT:	DB	"VGM"
MSG_NF:	DB	CR,LF,"NOT FOUND",CR,LF,00H
MSG_NOTVGM:
	DB	CR,LF,"NOT VGM",CR,LF,00H
MSG_BADHDR:
	DB	CR,LF,"BAD HEADER",CR,LF,00H
MSG_BADCMD:
	DB	CR,LF,"BAD COMMAND",CR,LF,00H
MSG_END:
	DB	CR,LF,"VGM END",CR,LF,00H

SAVSP:	DS	2			;SP退避
BLKSZ:	DS	4			;データブロックの残りサイズ
RBUF:		DS	RBUF_SIZE	;先読みリングバッファ
RBUF_END	EQU	$		;バッファ末尾＋1
RB_RDP:		DS	2		;読み出しポインタ
RB_WRP:		DS	2		;書き込みポインタ
RB_CNT:		DS	2		;バッファ内バイト数（0～RBUF_SIZE）
RB_EOF:		DS	1		;先読みが終端に達したら非0
WDEBT:		DS	2		;処理時間debt(サンプル)。主+ISRのSD精算ぶん
SD_DEBT:	DS	2		;ISRがSD補充に費やしたサンプル(WAIT_DEがWDEBTへ移す)
PLAYSP:		DS	02H			;再生中の脱出点SP
LISTCNT:	DS	01H			;一覧の件数
VGMCNT:		DS	01H			;VGM計数(選択用)
TARGETK:	DS	01H			;選択された番号(1始まり)
OPNREG:		DS	01H			;YM2203レジスタ番号一時
OPNDAT:		DS	01H			;YM2203データ一時
FILECNT:	DS	01H			;全ファイル件数
LISTBUF:	DS	MAXFILES*0DH		;一覧バッファ(1件13バイト)
PLAYNAME:	DS	0DH			;選択ファイル名

;--- 割り込み関連 ---
IVT_PTR:	DS	2			;$8000+(IVR_FMTAV) のキャッシュ
SAVED_VEC_FMTA:	DS	2			;元のベクタエントリ
TA_CTRL_SHADOW:	DS	1			;(未使用。互換のため残置)
TA_NA:		DS	2			;Timer Aプリロード値(ISRが毎tick再ロード)
IRQ_ACTIVE:	DS	1			;1=ISR稼働中(RB_GET/GETBの排他切替)
GETB_TO:	DS	2			;(未使用。互換のため残置)
ISR_CNT:	DS	2			;ISR発火回数(診断用。DONEでJ/K表示)
SD_ARMED:	DS	1			;1=この待ちでTimer A起動中(終了時に停止する目印)

;ISRが割り込み中に最深のSTRM_READ(セクタ/クラスタ跨ぎでMMC_BRD_CMD/READ_FATが
;さらに再帰)をメインのスタック上にネストするため厚めに確保する。
STACK:		DS	512		;プレイヤー専用スタック(ISRネスト分を上乗せ)
STACK_TOP	EQU	$		;スタック先頭(SPの初期値。下方向へ伸びる)

	END
