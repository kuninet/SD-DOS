;=================================================
;INTTEST - YM2203 Timer A IM2割り込みが「busy-loop中」に入るかの最小検証
;=================================================
;・VGM/SD等を一切排除し、割り込み受付だけを試す。
;・Timer A を一定周期で回し、ISRが入るたびにカウンタ++(再武装も行う)。
;・フェーズA: EIしてbusy-loop(~20ms)。その間にISRが入った回数を表示。
;・フェーズB: EIしてHALTを20回。その間にISRが入った回数を表示。
;・結果の読み方(画面表示 "A=nn B=nn"):
;    A>0          → busy-loop中でも割り込みは入る(私の実装の別バグ)
;    A=0 かつ B>0 → 割り込みはHALT中しか入らない(実機固有の制約が確定)
;    A=0 かつ B=0 → 割り込み自体が来ない(vector番号違い等)。9003H POKEで vector調整
;・vector番号は 9003H をPOKEで変えて総当たり可能(既定04H)。
;・使い方: LOAD → G9000。終了でBASICへ戻る。
;=================================================

OPN_ADDR	EQU	80H
OPN_DATA	EQU	81H
TA_REG_HI	EQU	24H
TA_REG_LO	EQU	25H
TA_REG_CTRL	EQU	27H
TA_CTRL_RUN_IRQEN	EQU	00000101B	;LoadA + IRQEN A
TA_CTRL_STOP_RESET	EQU	00010000B	;ResetA, LoadA=0
IVT_PAGE	EQU	80H
IVR_FMTA_DEFAULT	EQU	04H
TA_NA_VAL	EQU	934		;1024-90 ≒ 1.8ms周期(SPT=80相当)
CR		EQU	0DH
LF		EQU	0AH
BASIC		EQU	0081H

	ORG	9000H

	JP	START
IVR_FMTAV:	DB	IVR_FMTA_DEFAULT	;9003H POKE: vector番号(総当たり用)

START:
	LD	(SAVSP),SP
	LD	SP,STACK_TOP

	;--- IM2 ベクタ設置 ---
	DI
	LD	A,(IVR_FMTAV)
	LD	L,A
	LD	H,IVT_PAGE
	LD	(IVT_PTR),HL
	LD	E,(HL)			;旧ベクタ退避
	INC	HL
	LD	D,(HL)
	LD	(SAVED_VEC),DE
	LD	HL,(IVT_PTR)		;自前ISRを書く
	LD	DE,ISR
	LD	(HL),E
	INC	HL
	LD	(HL),D
	LD	A,IVT_PAGE
	LD	I,A
	IM	2

	;================= フェーズA: busy-loop =================
	LD	HL,MSG_A
	CALL	PUTS
	XOR	A
	LD	(INT_CNT),A
	CALL	TA_REARM		;タイマ起動
	EI
	;busy待ち(~20ms。周期1.8msなので入れば~11回)。HALTは一切しない。
	LD	DE,0
.bw:	INC	DE
	LD	A,D
	CP	10H			;DE=0x1000まで(~20ms)
	JR	NZ,.bw
	DI
	LD	A,(INT_CNT)		;busy中に入った回数を表示
	CALL	PRDEC

	;================= フェーズB: HALT =================
	LD	HL,MSG_B
	CALL	PUTS
	XOR	A
	LD	(INT_CNT),A
	CALL	TA_REARM
	LD	B,20
.hl:	EI
	HALT				;割り込みで起きる
	DJNZ	.hl
	DI
	LD	A,(INT_CNT)
	CALL	PRDEC

	;--- 後始末: タイマ停止・ベクタ復元・IM1・BASICへ ---
	CALL	TA_STOP
	LD	HL,(IVT_PTR)
	LD	DE,(SAVED_VEC)
	LD	(HL),E
	INC	HL
	LD	(HL),D
	IM	1
	EI
	LD	HL,MSG_CRLF
	CALL	PUTS
	JP	BASIC

;-------------------------------------------------
;ISR - 再武装 + カウンタ++(これが入れば割り込みが届いている)
;-------------------------------------------------
ISR:
	EX	AF,AF'
	EXX
	CALL	TA_REARM		;停止→ロード→再起動で次を再武装
	LD	HL,INT_CNT		;カウンタ++
	INC	(HL)
	EXX
	EX	AF,AF'
	EI
	RETI

;-------------------------------------------------
;TA_REARM - 停止→NAロード→起動。破壊 AF,BC,DE,HL
;-------------------------------------------------
TA_REARM:
	CALL	TA_STOP
	LD	HL,TA_NA_VAL
	CALL	TA_LOAD_HL
	CALL	TA_START
	RET

OPN_WR_RD:
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

TA_LOAD_HL:
	PUSH	BC
	PUSH	DE
	PUSH	HL
	PUSH	AF
	LD	C,L
	SRL	H
	RR	L
	SRL	H
	RR	L
	LD	D,TA_REG_HI
	LD	E,L
	CALL	OPN_WR_RD
	LD	A,C
	AND	03H
	LD	D,TA_REG_LO
	LD	E,A
	CALL	OPN_WR_RD
	POP	AF
	POP	HL
	POP	DE
	POP	BC
	RET

TA_START:
	PUSH	DE
	LD	D,TA_REG_CTRL
	LD	E,TA_CTRL_RUN_IRQEN
	CALL	OPN_WR_RD
	POP	DE
	RET

TA_STOP:
	PUSH	DE
	LD	D,TA_REG_CTRL
	LD	E,TA_CTRL_STOP_RESET
	CALL	OPN_WR_RD
	LD	D,TA_REG_CTRL
	LD	E,0
	CALL	OPN_WR_RD
	POP	DE
	RET

;A(0-255)を10進表示
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
	RST	18H
	RET

PUTS:	LD	A,(HL)
	OR	A
	RET	Z
	RST	18H
	INC	HL
	JR	PUTS

MSG_A:		DB	CR,LF,"A=",00H
MSG_B:		DB	" B=",00H
MSG_CRLF:	DB	CR,LF,00H

SAVSP:		DS	2
IVT_PTR:	DS	2
SAVED_VEC:	DS	2
INT_CNT:	DS	1
STACK:		DS	128
STACK_TOP	EQU	$

	END
