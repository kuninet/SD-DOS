;=================================================
;OPNCHK - YM2203 チップ応答チェックスケッチ
;=================================================
;・PSGビープでチップ自体の応答を耳で確認 + OPN書込み前後の80H観察
;・出力:
;    INIT 80=AA AA AA AA       ; 起動直後80H IN 4回
;    PSG-BEEP-START             ; PSGを叩いてビープ開始(約0.5秒)
;    PSG-BEEP-END               ; ビープ停止
;    OPN27 AA BB CC DD          ; 27H=FF書込み(addr→data)の各段階で80H IN
;    OPN24 AA BB CC DD          ; 24H=FF書込みの各段階
;    OPN28 AA BB CC DD          ; 28H=00書込み(KeyOff)の各段階
;・観察ポイント:
;    - PSGビープが「鳴る」=チップ電源/クロック/PSG部は生きている
;    - ビープが「鳴らない」=ボード全体未配線 or 電源/クロック問題
;    - OPNxx の途中で 80H が一度でも非0(特に80H=BUSY)になれば、OPN書込みは届いている
;    - OPNxx が全部 00H なら、80H書込みが届いていない or BUSYなし互換チップ
;=================================================

OPN_ADDR	EQU	80H
OPN_DATA	EQU	81H
PSG_ADDR	EQU	0A0H
PSG_DATA	EQU	0A1H

CR		EQU	0DH
LF		EQU	0AH
BASIC		EQU	0081H

	ORG	9000H

START:
	;--------------------------------------
	;起動直後の80H IN x4
	;--------------------------------------
	LD	HL,MSG_INIT
	CALL	PUTS
	LD	B,4
.r1:	IN	A,(OPN_ADDR)
	CALL	PRHEX2
	LD	A,' '
	RST	18H
	DJNZ	.r1
	CALL	CRLF

	;--------------------------------------
	;PSG ビープ
	;・チャンネルA: トーン周期 ~0x0080 (高めの音)
	;・ミキサ 38H = ノイズ無し, トーンA有効
	;・音量 0FH = 最大
	;--------------------------------------
	LD	HL,MSG_BEEP_S
	CALL	PUTS
	LD	A,0			;reg0 = トーンA低位
	OUT	(PSG_ADDR),A
	LD	A,80H
	OUT	(PSG_DATA),A
	LD	A,1			;reg1 = トーンA高位
	OUT	(PSG_ADDR),A
	LD	A,01H
	OUT	(PSG_DATA),A
	LD	A,7			;reg7 = ミキサ(下位bit反転論理: 0=有効)
	OUT	(PSG_ADDR),A
	LD	A,3EH			;トーンA有効、他はカット
	OUT	(PSG_DATA),A
	LD	A,8			;reg8 = chA音量
	OUT	(PSG_ADDR),A
	LD	A,0FH
	OUT	(PSG_DATA),A

	;ディレイ(約0.5秒)
	LD	BC,0
.dl:	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.dl

	;PSG オフ
	LD	A,7
	OUT	(PSG_ADDR),A
	LD	A,3FH			;全カット
	OUT	(PSG_DATA),A
	LD	A,8
	OUT	(PSG_ADDR),A
	LD	A,00H
	OUT	(PSG_DATA),A
	LD	HL,MSG_BEEP_E
	CALL	PUTS

	;--------------------------------------
	;OPN 27H=FF 書込み観察
	;・アドレス書込み前後 / データ書込み前後 で 80H をそれぞれ読む
	;--------------------------------------
	LD	HL,MSG_OPN27
	CALL	PUTS
	IN	A,(OPN_ADDR)		;書込み前
	CALL	PRHEX2
	LD	A,' '
	RST	18H
	LD	A,27H
	OUT	(OPN_ADDR),A
	IN	A,(OPN_ADDR)		;アドレス書込み直後
	CALL	PRHEX2
	LD	A,' '
	RST	18H
	LD	A,0FFH
	OUT	(OPN_DATA),A
	IN	A,(OPN_ADDR)		;データ書込み直後
	CALL	PRHEX2
	LD	A,' '
	RST	18H
	IN	A,(OPN_ADDR)		;少し後
	CALL	PRHEX2
	CALL	CRLF

	;--------------------------------------
	;OPN 24H=FF 書込み観察
	;--------------------------------------
	LD	HL,MSG_OPN24
	CALL	PUTS
	IN	A,(OPN_ADDR)
	CALL	PRHEX2
	LD	A,' '
	RST	18H
	LD	A,24H
	OUT	(OPN_ADDR),A
	IN	A,(OPN_ADDR)
	CALL	PRHEX2
	LD	A,' '
	RST	18H
	LD	A,0FFH
	OUT	(OPN_DATA),A
	IN	A,(OPN_ADDR)
	CALL	PRHEX2
	LD	A,' '
	RST	18H
	IN	A,(OPN_ADDR)
	CALL	PRHEX2
	CALL	CRLF

	;--------------------------------------
	;OPN 28H=00 書込み観察(KeyOff)
	;--------------------------------------
	LD	HL,MSG_OPN28
	CALL	PUTS
	IN	A,(OPN_ADDR)
	CALL	PRHEX2
	LD	A,' '
	RST	18H
	LD	A,28H
	OUT	(OPN_ADDR),A
	IN	A,(OPN_ADDR)
	CALL	PRHEX2
	LD	A,' '
	RST	18H
	LD	A,00H
	OUT	(OPN_DATA),A
	IN	A,(OPN_ADDR)
	CALL	PRHEX2
	LD	A,' '
	RST	18H
	IN	A,(OPN_ADDR)
	CALL	PRHEX2
	CALL	CRLF

	JP	BASIC

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

MSG_INIT:	DB	CR,LF,"INIT 80=",00H
MSG_BEEP_S:	DB	"PSG-BEEP-START",CR,LF,00H
MSG_BEEP_E:	DB	"PSG-BEEP-END",CR,LF,00H
MSG_OPN27:	DB	"OPN27 ",00H
MSG_OPN24:	DB	"OPN24 ",00H
MSG_OPN28:	DB	"OPN28 ",00H

	END
