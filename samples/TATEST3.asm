;=================================================
;TATEST3 - YM2203 Timer A 起動パターン総当たり
;=================================================
;・27H に書く値を変えて、50ms 後の 80H ステータスを観察する
;・bit0(Timer A flag) が 1 なら overflow した = Timer A が動いた
;・各テスト前に N-BASIC 起動直後相当にしたいので 27H=30H(両Reset) で
;  Timer停止 + flagクリアしてから 24H=00,25H=00 に戻し、テスト値を書く
;
;・出力(80=XX はテスト書込み後50ms時点の値):
;    INIT  =XX XX XX XX
;    T01 27=01 80=XX     ; LoadA のみ
;    T02 27=05 80=XX     ; LoadA + IRQEN A
;    T03 27=11 80=XX     ; LoadA + ResetA
;    T04 27=15 80=XX     ; LoadA + IRQEN A + ResetA
;    T05 27=03 80=XX     ; LoadA + LoadB
;    T06 27=0F 80=XX     ; LoadA+LoadB+IRQEN A+IRQEN B
;    T07 27=FF 80=XX     ; 全bit (OPNCHK相当)
;
;・80=01 or 03 or 81 or 83 が出れば bit0(Timer A overflow) が立った=該当パターンで起動
;・どれも 00 のまま → 27H レイアウト推定が違う可能性
;=================================================

OPN_ADDR	EQU	80H
OPN_DATA	EQU	81H

TA_REG_HI	EQU	24H
TA_REG_LO	EQU	25H
TA_REG_CTRL	EQU	27H

CR		EQU	0DH
LF		EQU	0AH
BASIC		EQU	0081H

	ORG	9000H

START:
	;起動直後の80H IN x4
	LD	HL,MSG_INIT
	CALL	PUTS
	LD	B,4
.r:	IN	A,(OPN_ADDR)
	CALL	PRHEX2
	LD	A,' '
	RST	18H
	DJNZ	.r
	CALL	CRLF

	;NA=0 にして 1024 tick (約20.6ms) でoverflowするようプリセット
	LD	D,TA_REG_HI
	LD	E,00H
	CALL	OPN_WR
	LD	D,TA_REG_LO
	LD	E,00H
	CALL	OPN_WR

	;以下、各パターンを試行
	LD	HL,MSG_T01
	CALL	PUTS
	LD	A,01H
	CALL	TEST_ONE

	LD	HL,MSG_T02
	CALL	PUTS
	LD	A,05H
	CALL	TEST_ONE

	LD	HL,MSG_T03
	CALL	PUTS
	LD	A,11H
	CALL	TEST_ONE

	LD	HL,MSG_T04
	CALL	PUTS
	LD	A,15H
	CALL	TEST_ONE

	LD	HL,MSG_T05
	CALL	PUTS
	LD	A,03H
	CALL	TEST_ONE

	LD	HL,MSG_T06
	CALL	PUTS
	LD	A,0FH
	CALL	TEST_ONE

	LD	HL,MSG_T07
	CALL	PUTS
	LD	A,0FFH
	CALL	TEST_ONE

	;最後に Timer 停止 (Reset 両方)
	LD	D,TA_REG_CTRL
	LD	E,30H
	CALL	OPN_WR

	JP	BASIC

;-------------------------------------------------
;TEST_ONE - A の値を 27H に書き、50ms 後の 80H を表示
; 1) 27H=30H で停止+両Reset (前のテストの影響をクリア)
; 2) 27H=00 で完全idle (Load bit を一度0に)
; 3) 27H=A (テスト値)
; 4) 約50ms ディレイ
; 5) 80H IN を表示
;-------------------------------------------------
TEST_ONE:
	PUSH	AF
	LD	D,TA_REG_CTRL
	LD	E,30H
	CALL	OPN_WR
	LD	D,TA_REG_CTRL
	LD	E,00H
	CALL	OPN_WR
	POP	AF
	LD	D,TA_REG_CTRL
	LD	E,A
	CALL	OPN_WR
	CALL	DELAY_50MS
	IN	A,(OPN_ADDR)
	CALL	PRHEX2
	CALL	CRLF
	RET

;-------------------------------------------------
;DELAY_50MS - 約50ms ディレイ (Z80 4MHz想定)
; 16384 * 約 12 cycle = 約 49ms
;-------------------------------------------------
DELAY_50MS:
	PUSH	BC
	LD	BC,4000H
.lp:	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.lp
	POP	BC
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
MSG_T01:	DB	"T01 27=01 80=",00H
MSG_T02:	DB	"T02 27=05 80=",00H
MSG_T03:	DB	"T03 27=11 80=",00H
MSG_T04:	DB	"T04 27=15 80=",00H
MSG_T05:	DB	"T05 27=03 80=",00H
MSG_T06:	DB	"T06 27=0F 80=",00H
MSG_T07:	DB	"T07 27=FF 80=",00H

	END
