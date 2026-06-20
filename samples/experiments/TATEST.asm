;=================================================
;TATEST - YM2203 Timer A 動作切り分けスケッチ(3パターン試行)
;=================================================
;・3つのパターンで Timer A を起動し、それぞれ 5 回ずつ overflow を polling
;・各パターン直前に 27H 書込み後の80Hステータスも表示
;
;  P1: NA=1023 (24H=FF, 25H=03) → 27H=10H(StopReset) → 27H=01H(LoadA)
;      ・1 tick で即座にoverflow するはず(プリロード計算と無関係に動作確認)
;  P2: NA=0    (24H=00, 25H=00) → 27H=10H → 27H=01H
;      ・最大周期(約18ms @4MHz想定)
;  P3: NA=0    (24H=00, 25H=00) → 27H=11H(LoadA+ResetA 同時)
;      ・Load bit の立ち上がりエッジが要る場合の試行
;
;・出力:
;    STAT=AA BB CC DD       ; 起動直後のステータス4回
;    P1 27H=ZZ +++++         ; パターン1の 27H直後STAT と 5回の結果
;    P2 27H=ZZ -----         ; パターン2
;    P3 27H=ZZ +++++         ; パターン3
;    BUSY=ZZ                ; 最終ステータス
;
;・全部 + → Timer A は普通に動く。VGMIRQP の使い方の問題
;・P1 だけ + → NA=0 が想定通りでない(カウンタリロード仕様の違い)
;・全部 - → 27H ビット配置 or Timer A クロック供給が想定と違う
;=================================================

OPN_ADDR	EQU	80H
OPN_DATA	EQU	81H

TA_REG_HI	EQU	24H
TA_REG_LO	EQU	25H
TA_REG_CTRL	EQU	27H
TA_STAT_FLAG_A_MASK	EQU	01H

CR		EQU	0DH
LF		EQU	0AH
BASIC		EQU	0081H

	ORG	9000H

START:
	;起動直後の80Hステータスを4回連続で読み表示
	LD	HL,MSG_STAT
	CALL	PUTS
	LD	B,4
.r:	IN	A,(OPN_ADDR)
	CALL	PRHEX2
	LD	A,' '
	RST	18H
	DJNZ	.r
	CALL	CRLF

	;念のため YM2203 を停止状態に
	LD	D,TA_REG_CTRL
	LD	E,10H
	CALL	OPN_WR

	;------------------------------------------
	;パターン1: NA=1023 (1 tick で即overflow するはず)
	;------------------------------------------
	LD	HL,MSG_P1
	CALL	PUTS
	LD	D,TA_REG_HI
	LD	E,0FFH			;NA=1023 の上位8bit
	CALL	OPN_WR
	LD	D,TA_REG_LO
	LD	E,03H			;NA=1023 の下位2bit
	CALL	OPN_WR
	LD	A,01H			;StopReset → Load 切替なし、いきなり Load
	CALL	RUN_AND_POLL
	CALL	CRLF

	;------------------------------------------
	;パターン2: NA=0 (最大周期)
	;------------------------------------------
	LD	HL,MSG_P2
	CALL	PUTS
	LD	D,TA_REG_HI
	LD	E,00H
	CALL	OPN_WR
	LD	D,TA_REG_LO
	LD	E,00H
	CALL	OPN_WR
	LD	A,01H
	CALL	RUN_AND_POLL
	CALL	CRLF

	;------------------------------------------
	;パターン3: NA=0, Reset+Load同時 (27H=11H 一発)
	;------------------------------------------
	LD	HL,MSG_P3
	CALL	PUTS
	LD	D,TA_REG_HI
	LD	E,00H
	CALL	OPN_WR
	LD	D,TA_REG_LO
	LD	E,00H
	CALL	OPN_WR
	LD	A,11H			;LoadA + ResetA 同時
	CALL	RUN_AND_POLL
	CALL	CRLF

	;最終ステータス
	LD	HL,MSG_BUSY
	CALL	PUTS
	IN	A,(OPN_ADDR)
	CALL	PRHEX2
	CALL	CRLF

	;Timer A 停止
	LD	D,TA_REG_CTRL
	LD	E,10H
	CALL	OPN_WR

	JP	BASIC

;-------------------------------------------------
;RUN_AND_POLL - 27Hに A を書込み、直後STAT表示後 5回polling
; IN: A = 27H に書く値
;-------------------------------------------------
RUN_AND_POLL:
	;いったん停止
	PUSH	AF
	LD	D,TA_REG_CTRL
	LD	E,10H
	CALL	OPN_WR
	;指定値で起動
	POP	AF
	LD	D,TA_REG_CTRL
	LD	E,A
	CALL	OPN_WR

	;27H書込み直後の STAT 表示
	LD	HL,MSG_27H
	CALL	PUTS
	IN	A,(OPN_ADDR)
	CALL	PRHEX2
	LD	A,' '
	RST	18H

	;5回 polling
	LD	C,5
.t:	CALL	POLL_ONCE
	;flag リセット
	LD	D,TA_REG_CTRL
	LD	E,11H
	CALL	OPN_WR
	LD	D,TA_REG_CTRL
	LD	E,01H
	CALL	OPN_WR
	DEC	C
	JR	NZ,.t
	RET

;-------------------------------------------------
;POLL_ONCE - bit0 が立つまで polling(タイムアウト約0.5秒)
;-------------------------------------------------
POLL_ONCE:
	LD	HL,0
.pl:	IN	A,(OPN_ADDR)
	AND	TA_STAT_FLAG_A_MASK
	JR	NZ,.hit
	INC	HL
	LD	A,H
	CP	80H
	JR	NZ,.pl
	LD	A,'-'
	RST	18H
	RET
.hit:	LD	A,'+'
	RST	18H
	RET

;-------------------------------------------------
;OPN_WR - YM2203 1レジスタ書込(BUSY待ち入り)
; IN: D = レジスタ番号, E = データ
;-------------------------------------------------
OPN_WR:
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
PRHEX2:
	PUSH	AF
	RRA
	RRA
	RRA
	RRA
	CALL	PRHEX1
	POP	AF
	CALL	PRHEX1
	RET
PRHEX1:
	AND	0FH
	ADD	A,30H
	CP	3AH
	JR	C,.o
	ADD	A,7
.o:	RST	18H
	RET

CRLF:	LD	A,CR
	RST	18H
	LD	A,LF
	RST	18H
	RET

PUTS:	LD	A,(HL)
	OR	A
	RET	Z
	RST	18H
	INC	HL
	JR	PUTS

MSG_STAT:	DB	CR,LF,"STAT=",00H
MSG_P1:		DB	"P1 ",00H
MSG_P2:		DB	"P2 ",00H
MSG_P3:		DB	"P3 ",00H
MSG_27H:	DB	"27H=",00H
MSG_BUSY:	DB	"BUSY=",00H

	END
