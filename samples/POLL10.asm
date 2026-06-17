;=================================================
;POLL10 - Timer A polling の最小動作確認(SD/VGM一切なし)
;=================================================
;・VGMIRQP の polling 部分だけを取り出して単独実行する
;・27H = 15H(Reset+LoadA+IRQEN A) → 27H = 05H(LoadA+IRQEN A) → polling
;・10 回繰り返し。bit0 立ちで '+'、タイムアウトで '-'
;・polling 区間のみ DI、抜けたら Timer A 停止+flagクリア+EI
;・出力:
;    INIT  =XX XX XX XX        ; 起動直後80H IN x4
;    POLL: ++++++++++           ; 10回polling
;    FINAL =XX                  ; 終了後80H IN
;
;・10個+なら VGMIRQP の polling シーケンスは単独で動く
;  → VGMIRQP がハングするのは polling の手前 (GETB/OPN書込み等) の問題
;・どれか-なら polling シーケンス自体に問題
;・全くハングするなら DI/EI 周りで CPU が死ぬ
;=================================================

OPN_ADDR	EQU	80H
OPN_DATA	EQU	81H

TA_REG_HI	EQU	24H
TA_REG_LO	EQU	25H
TA_REG_CTRL	EQU	27H

TA_CTRL_RUN_POLL	EQU	00000101B
TA_CTRL_RUN_RESET_A	EQU	00010101B
TA_CTRL_STOP_RESET	EQU	00010000B
TA_FLAG_A_MASK		EQU	00000001B

CR	EQU	0DH
LF	EQU	0AH
BASIC	EQU	0081H

	ORG	9000H

START:
	;起動直後の80H IN
	LD	HL,MSG_INIT
	CALL	PUTS
	LD	B,4
.r:	IN	A,(OPN_ADDR)
	CALL	PRHEX2
	LD	A,' '
	RST	18H
	DJNZ	.r
	CALL	CRLF

	;Timer A プリロード NA=0 (周期 約20ms)
	LD	D,TA_REG_HI
	LD	E,00H
	CALL	OPN_WR
	LD	D,TA_REG_LO
	LD	E,00H
	CALL	OPN_WR

	;Timer A 停止
	LD	D,TA_REG_CTRL
	LD	E,TA_CTRL_STOP_RESET
	CALL	OPN_WR
	LD	D,TA_REG_CTRL
	LD	E,00H
	CALL	OPN_WR

	;polling 10回
	LD	HL,MSG_POLL
	CALL	PUTS

	LD	B,10
.lp:
	DI				;polling区間のみ割込み禁止

	;Reset+Run+IRQEN → Run+IRQEN
	LD	D,TA_REG_CTRL
	LD	E,TA_CTRL_RUN_RESET_A
	CALL	OPN_WR
	LD	D,TA_REG_CTRL
	LD	E,TA_CTRL_RUN_POLL
	CALL	OPN_WR

	;bit0 polling (タイムアウト ~0.5秒)
	PUSH	HL
	LD	HL,0
.pl:	IN	A,(OPN_ADDR)
	AND	TA_FLAG_A_MASK
	JR	NZ,.hit
	INC	HL
	LD	A,H
	CP	80H
	JR	NZ,.pl
	POP	HL
	;タイムアウト
	CALL	TA_STOP
	EI
	LD	A,'-'
	RST	18H
	JR	.next
.hit:	POP	HL

	CALL	TA_STOP			;/IRQを降ろす
	EI

	LD	A,'+'
	RST	18H

.next:
	DJNZ	.lp

	CALL	CRLF

	;最終ステータス
	LD	HL,MSG_FINAL
	CALL	PUTS
	IN	A,(OPN_ADDR)
	CALL	PRHEX2
	CALL	CRLF

	JP	BASIC

;-------------------------------------------------
;TA_STOP - Timer A停止+flagクリア
;-------------------------------------------------
TA_STOP:
	PUSH	DE
	LD	D,TA_REG_CTRL
	LD	E,TA_CTRL_STOP_RESET
	CALL	OPN_WR
	LD	D,TA_REG_CTRL
	LD	E,00H
	CALL	OPN_WR
	POP	DE
	RET

;-------------------------------------------------
;OPN_WR - YM2203 1レジスタ書込(BUSY待ち入り)
;-------------------------------------------------
OPN_WR:
	PUSH	AF
.busy:	IN	A,(OPN_ADDR)
	RLCA
	JR	C,.busy
	LD	A,D
	OUT	(OPN_ADDR),A
	LD	A,D
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

MSG_INIT:	DB	CR,LF,"INIT  =",00H
MSG_POLL:	DB	"POLL: ",00H
MSG_FINAL:	DB	"FINAL =",00H

	END
