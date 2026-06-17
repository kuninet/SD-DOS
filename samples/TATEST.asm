;=================================================
;TATEST - YM2203 Timer A 単体動作確認スケッチ
;=================================================
;・VGM/SD/メニューなし。起動直後に Timer A の挙動だけを観察する
;・実機 G9000 で実行する
;・出力フォーマット:
;    STAT=AA BB CC DD       ; 起動直後の80Hステータス読み4回
;    +++++++++++           ; Timer A overflow が来た (10回試行ぶん)
;    ----------            ; タイムアウト(来なかった)
;    BUSY=ZZ                ; 最終ステータス読み
;・Timer A プリロード = 24H/25H ともに 0H → NA=0 → 最大周期 (約18ms @4MHz想定)
;・27H = 01H (LoadA=1, IRQEN A=0) で起動
;・タイムアウト判定: polling ループ 32768 回 (~0.2秒 @4MHz)
;・bit0 (Timer A overflow) を待ち、立てば '+'、ループ上限到達で '-'
;=================================================

OPN_ADDR	EQU	80H
OPN_DATA	EQU	81H

TA_REG_HI	EQU	24H
TA_REG_LO	EQU	25H
TA_REG_CTRL	EQU	27H
TA_CTRL_RUN_POLL	EQU	01H	;LoadA=1, IRQEN A=0
TA_CTRL_RESET_A		EQU	11H	;LoadA=1 + ResetA=1 (flagパルスリセット)
TA_CTRL_STOP_RESET	EQU	10H	;ResetA=1 (停止+flagクリア)
TA_STAT_FLAG_A_MASK	EQU	01H

CR		EQU	0DH
LF		EQU	0AH
BASIC		EQU	0081H

	ORG	9000H

START:
	;起動直後の80Hステータスを4回連続で読み、画面に表示する
	LD	HL,MSG_STAT
	CALL	PUTS
	LD	B,4
.r:	IN	A,(OPN_ADDR)
	CALL	PRHEX2
	LD	A,' '
	RST	18H
	DJNZ	.r
	CALL	CRLF

	;Timer A プリロード = 0
	LD	D,TA_REG_HI
	LD	E,0
	CALL	OPN_WR
	LD	D,TA_REG_LO
	LD	E,0
	CALL	OPN_WR
	;念のため Timer A 停止状態にしておく
	LD	D,TA_REG_CTRL
	LD	E,TA_CTRL_STOP_RESET
	CALL	OPN_WR

	;10回試行
	LD	B,10
.loop:
	;Timer A 起動
	LD	D,TA_REG_CTRL
	LD	E,TA_CTRL_RUN_POLL
	CALL	OPN_WR

	;polling ループ (タイムアウト付き)
	LD	HL,0
.pl:	IN	A,(OPN_ADDR)
	AND	TA_STAT_FLAG_A_MASK
	JR	NZ,.hit
	INC	HL
	LD	A,H
	CP	80H			;HL > 0x8000 でタイムアウト
	JR	NZ,.pl
	LD	A,'-'
	RST	18H
	JR	.next
.hit:	LD	A,'+'
	RST	18H
.next:
	;Timer A flag リセット → 走行状態に戻す
	LD	D,TA_REG_CTRL
	LD	E,TA_CTRL_RESET_A
	CALL	OPN_WR
	LD	D,TA_REG_CTRL
	LD	E,TA_CTRL_RUN_POLL
	CALL	OPN_WR
	DJNZ	.loop

	CALL	CRLF

	;最終ステータスを表示 (BUSY等の観察)
	LD	HL,MSG_BUSY
	CALL	PUTS
	IN	A,(OPN_ADDR)
	CALL	PRHEX2
	CALL	CRLF

	;Timer A 停止して終了
	LD	D,TA_REG_CTRL
	LD	E,TA_CTRL_STOP_RESET
	CALL	OPN_WR

	JP	BASIC

;-------------------------------------------------
;OPN_WR - YM2203 1レジスタ書込(BUSY待ち入り)
; IN: D = レジスタ番号, E = データ
;-------------------------------------------------
OPN_WR:
	PUSH	AF
.busy:	IN	A,(OPN_ADDR)		;BUSY=bit7
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
;PRHEX2 - A を 16進2桁で表示
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
MSG_BUSY:	DB	"BUSY=",00H

	END
