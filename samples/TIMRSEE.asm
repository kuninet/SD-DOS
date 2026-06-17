;=================================================
;TIMRSEE - YM2203 Timer A/B flag を「何も書かずに観察」する
;=================================================
;・OPN に一切書込みを行わない
;・80H ステータスを連続で読み、各タイミングでの値を表示
;・Timer A flag (bit0) が立ったら '+'、タイムアウトで '-'
;・Timer B flag (bit1) も同様に観察(別ループ)
;
;・出力:
;    INIT  =XX XX XX XX        ; 起動直後 80H IN x4
;    AFTER1=XX                  ; ループ1終了後 80H IN
;    POLL-A: +++++              ; Timer A flag(bit0)を5回連続待ち
;    AFTER2=XX                  ; A polling後
;    POLL-B: +++++              ; Timer B flag(bit1)を5回連続待ち
;    AFTER3=XX                  ; B polling後
;
;・どちらかが '+++++' なら Timer は走り続けている=
;  Stop/Start シーケンスを書くTATESTのアプローチが原因
;・どちらも '-----' なら、起動時の flag は残骸でTimerは動いていない
;・Timer A だけ '-----' なら Timer A だけ停止状態
;=================================================

OPN_ADDR	EQU	80H

CR		EQU	0DH
LF		EQU	0AH
BASIC		EQU	0081H

	ORG	9000H

START:
	;起動直後の80H IN x4
	LD	HL,MSG_INIT
	CALL	PUTS
	LD	B,4
.r1:	IN	A,(OPN_ADDR)
	CALL	PRHEX2
	LD	A,' '
	RST	18H
	DJNZ	.r1
	CALL	CRLF

	;ループ1終了後の80H IN
	LD	HL,MSG_A1
	CALL	PUTS
	IN	A,(OPN_ADDR)
	CALL	PRHEX2
	CALL	CRLF

	;Timer A flag (bit0) を 5 回待つ
	LD	HL,MSG_POLLA
	CALL	PUTS
	LD	C,5
.tA:	CALL	POLL_BIT0
	DEC	C
	JR	NZ,.tA
	CALL	CRLF

	LD	HL,MSG_A2
	CALL	PUTS
	IN	A,(OPN_ADDR)
	CALL	PRHEX2
	CALL	CRLF

	;Timer B flag (bit1) を 5 回待つ
	LD	HL,MSG_POLLB
	CALL	PUTS
	LD	C,5
.tB:	CALL	POLL_BIT1
	DEC	C
	JR	NZ,.tB
	CALL	CRLF

	LD	HL,MSG_A3
	CALL	PUTS
	IN	A,(OPN_ADDR)
	CALL	PRHEX2
	CALL	CRLF

	JP	BASIC

;-------------------------------------------------
;POLL_BIT0 - bit0 が立つまでまつ(タイムアウト ~0.5秒)
;・Timer flag は ResetAなどで消えないので、立ってたら即抜ける
;-------------------------------------------------
POLL_BIT0:
	LD	HL,0
.pl:	IN	A,(OPN_ADDR)
	AND	01H
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

POLL_BIT1:
	LD	HL,0
.pl:	IN	A,(OPN_ADDR)
	AND	02H
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
MSG_A1:		DB	"AFTER1=",00H
MSG_POLLA:	DB	"POLL-A: ",00H
MSG_A2:		DB	"AFTER2=",00H
MSG_POLLB:	DB	"POLL-B: ",00H
MSG_A3:		DB	"AFTER3=",00H

	END
