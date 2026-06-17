;=================================================
;VGMIRQP - VGMIRQ の Polling デバッグ版(Timer A 動作確認用)
;=================================================
;・VGMIRQ.asm から「Z80 IM 2 割り込み経路」を切り離した版
;・I レジスタ/IM/ベクタテーブルには触らない(N-BASIC の状態をそのまま維持)
;・YM2203 Timer A は「IRQ enable=0、LoadA=1」で走らせ、80H のステータス読みで
;  bit0(Timer A overflow)を polling で確認する
;・これが正しく鳴れば: Timer A のレジスタ書き込み・プリロード換算・27Hビット配置
;  は OK。残る容疑者は「IRQ経路(INTJP→/INT→vector→ISR ジャンプ)」になる
;・鳴らなければ: Timer A 設定自体 or 27H ビット配置が想定と違う
;・FM /IRQ の物理配線・232C INTJP vector encoding はこの版では関係しない
;・使い方: LOAD "VGMIRQP.CMT" :(必要ならCD): モニタ G9000
;・コードは VGMIRQ.asm からの差分のみで、メニュー/ヘッダ解析/SD I/O は同等
;=================================================

STRM_OPEN	EQU	6005H
STRM_READ	EQU	6008H
STRM_CLOSE	EQU	600BH
STRM_DIRLIST	EQU	600EH

OPN_ADDR	EQU	80H		;YM2203 アドレス書込/ステータス読み
OPN_DATA	EQU	81H		;YM2203 データ
PSG_ADDR	EQU	0A0H
PSG_DATA	EQU	0A1H

CR		EQU	0DH
LF		EQU	0AH
BASIC		EQU	0081H
KEYWAIT		EQU	0F75H
MAXFILES	EQU	40H

;--- YM2203 Timer A ---
TA_REG_HI	EQU	24H
TA_REG_LO	EQU	25H
TA_REG_CTRL	EQU	27H
;27Hビット配置(VGMIRQと同じ前提): bit0=LoadA, bit1=LoadB, bit2=IRQEN A,
;                                  bit3=IRQEN B, bit4=ResetA, bit5=ResetB
TA_CTRL_RUN_POLL	EQU	00000001B	;LoadA=1, IRQEN A=0(割込なし)
TA_CTRL_RUN_RESET_A	EQU	00010001B	;LoadA=1, ResetA=1(flagパルスリセット)
TA_CTRL_STOP_RESET	EQU	00010000B	;ResetA=1のみ(停止+flagクリア)
TA_STAT_FLAG_A_MASK	EQU	00000001B	;ステータス読みのbit0

;--- サンプル -> Timer A tick 換算(VGMIRQと同じ仮定値) ---
TICKS_PER_SAMPLE_X256	EQU	322
MAX_SAMPLES_PER_CHUNK	EQU	512
MAX_CHUNK_HI	EQU	02H
MAX_CHUNK_LO	EQU	00H
NA_MAX_CHUNK	EQU	379

;--- リングバッファ(VGMIRQと同じサイズ) ---
RBUF_SIZE	EQU	4500H
INITFILL	EQU	2000H
RBUF_HIWATER	EQU	RBUF_SIZE - 0100H
FILL_BURST	EQU	04H

	ORG	9000H

	JP	START			;9000H 実行エントリ(モニタG9000)
FILL_BURSTV:	DB	FILL_BURST	;9003H POKE: HALT前(polling前)の補充回数上限
DBG_RSV1:	DB	0		;9004H 予約
DBG_RSV2:	DB	0		;9005H 予約

START:
	LD	(SAVSP),SP
	LD	SP,STACK_TOP

MENU:
	CALL	BUILD_LIST
	LD	A,(LISTCNT)
	OR	A
	JP	Z,BASIC
	CALL	READ_NUM
	LD	A,H
	OR	A
	JR	NZ,MENU
	LD	A,L
	OR	A
	JP	Z,BASIC
	LD	A,(LISTCNT)
	CP	L
	JR	C,MENU
	LD	A,L
	CALL	GET_NTH_VGM
	JR	C,MENU
	CALL	PLAY_FILE
	JR	MENU

;-------------------------------------------------
;正常終了
;-------------------------------------------------
DONE:
	LD	SP,(PLAYSP)
	CALL	TA_STOP_POLL		;Timer A停止のみ。IRQ環境は触っていない
	CALL	STRM_CLOSE
	LD	HL,MSG_END
	CALL	PUTS
	RET

;-------------------------------------------------
;異常終了
;-------------------------------------------------
ABORT:
	LD	SP,(PLAYSP)
	PUSH	HL
	CALL	TA_STOP_POLL
	CALL	STRM_CLOSE
	POP	HL
	CALL	PUTS
	RET

;-------------------------------------------------
;ヘッダ解析(VGMIRQと同じ)
;-------------------------------------------------
PARSE_HDR:
	LD	HL,IDENT
	LD	B,4
.ID:	CALL	GETB
	CP	(HL)
	JR	NZ,.NOTVGM
	INC	HL
	DJNZ	.ID
	LD	DE,4
	CALL	SKIP
	CALL	GETB
	LD	C,A
	CALL	GETB
	LD	B,A
	CALL	GETB
	CALL	GETB
	LD	H,B
	LD	L,C
	LD	DE,0150H
	OR	A
	SBC	HL,DE
	JR	C,.OLD
	LD	DE,0028H
	CALL	SKIP
	CALL	GETB
	LD	E,A
	CALL	GETB
	LD	D,A
	CALL	GETB
	LD	C,A
	CALL	GETB
	OR	C
	JR	NZ,.BADHDR
	EX	DE,HL
	LD	DE,4
	OR	A
	SBC	HL,DE
	JR	C,.BADHDR
	EX	DE,HL
	JP	SKIP

.OLD:	LD	DE,0034H
	JP	SKIP

.NOTVGM:	LD	HL,MSG_NOTVGM
	JP	ABORT
.BADHDR:	LD	HL,MSG_BADHDR
	JP	ABORT

;-------------------------------------------------
;再生ループ
;-------------------------------------------------
PLAY:
.LOOP:	CALL	GETB
	CP	66H
	JP	Z,DONE
	CP	55H
	JR	Z,.OPN
	CP	0A0H
	JR	Z,.PSG
	CP	61H
	JR	Z,.W61
	CP	62H
	JR	Z,.W62
	CP	63H
	JR	Z,.W63
	LD	C,A
	AND	0F0H
	CP	70H
	JR	Z,.W7X
	CP	80H
	JR	Z,.LOOP
	LD	A,C
	JP	SKIP_CMD

.OPN:	CALL	GETB
	LD	(OPNREG),A
	CALL	GETB
	LD	(OPNDAT),A
.BUSY:	IN	A,(OPN_ADDR)
	RLCA
	JR	C,.BUSY
	LD	A,(OPNREG)
	OUT	(OPN_ADDR),A
	LD	A,(OPNREG)
	LD	A,(OPNDAT)
	OUT	(OPN_DATA),A
	JP	PLAY.LOOP

.PSG:	CALL	GETB
	OUT	(PSG_ADDR),A
	CALL	GETB
	OUT	(PSG_DATA),A
	JP	PLAY.LOOP

.W61:	CALL	GETB
	LD	E,A
	CALL	GETB
	LD	D,A
	CALL	WAIT_DE_POLL
	JP	PLAY.LOOP
.W62:	LD	DE,735
	CALL	WAIT_DE_POLL
	JP	PLAY.LOOP
.W63:	LD	DE,882
	CALL	WAIT_DE_POLL
	JP	PLAY.LOOP
.W7X:	LD	A,C
	AND	0FH
	INC	A
	LD	E,A
	LD	D,0
	CALL	WAIT_DE_POLL
	JP	PLAY.LOOP

;-------------------------------------------------
;未対応コマンドの読み飛ばし(VGMIRQと同じ)
;-------------------------------------------------
SKIP_CMD:
	CP	30H
	JR	C,.BAD
	CP	40H
	JR	C,.S1
	CP	4FH
	JR	C,.BAD
	CP	51H
	JR	C,.S1
	CP	60H
	JR	C,.S2
	CP	64H
	JR	Z,.S3
	CP	67H
	JR	Z,.BLK
	CP	90H
	JR	C,.BAD
	CP	96H
	JR	C,.S9X
	CP	0A1H
	JR	C,.BAD
	CP	0C0H
	JR	C,.S2
	CP	0E0H
	JR	C,.S3
.S4:	CALL	GETB
.S3:	CALL	GETB
.S2:	CALL	GETB
.S1:	CALL	GETB
	JP	PLAY.LOOP

.BAD:	LD	HL,MSG_BADCMD
	JP	ABORT

.S9X:	SUB	90H
	LD	HL,TBL9X
	LD	E,A
	LD	D,0
	ADD	HL,DE
	LD	B,(HL)
.S9L:	CALL	GETB
	DJNZ	.S9L
	JP	PLAY.LOOP

.BLK:	CALL	GETB
	CALL	GETB
	LD	HL,BLKSZ
	LD	B,4
.BSZ:	CALL	GETB
	LD	(HL),A
	INC	HL
	DJNZ	.BSZ
.BSKIP:	LD	HL,BLKSZ
	LD	B,4
	XOR	A
.BZ:	OR	(HL)
	INC	HL
	DJNZ	.BZ
	OR	A
	JP	Z,PLAY.LOOP
	LD	HL,BLKSZ
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

SKIP:	LD	A,D
	OR	E
	RET	Z
	CALL	GETB
	DEC	DE
	JR	SKIP

;-------------------------------------------------
;1バイト取得
;-------------------------------------------------
GETB:	PUSH	HL
	PUSH	DE
	PUSH	BC
	CALL	RB_GET
	JR	NC,.GOT
	LD	A,(RB_EOF)
	OR	A
	JR	NZ,.EOF
	CALL	STRM_READ
	JR	C,.RDEOF
.GOT:	POP	BC
	POP	DE
	POP	HL
	RET
.RDEOF:	LD	A,0FFH
	LD	(RB_EOF),A
.EOF:	POP	BC
	POP	DE
	POP	HL
	JP	DONE

;=================================================
;OPN_WR_RD - YM2203 1レジスタ書込(BUSY待ち入り)
; IN: D = レジスタ番号, E = データ
; AF を保存、D/E は破壊しない
;=================================================
OPN_WR_RD:
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

;=================================================
;WAIT_DE_POLL - Timer Aを走らせ、ステータスのbit0をpollingで待つ
; IN: DE = サンプル数
;=================================================
WAIT_DE_POLL:
.LOOP:	LD	A,D
	OR	E
	RET	Z

	CALL	CALC_TA_CHUNK		;OUT: BC=今回消費, HL=NA, DE=残り
	CALL	TA_LOAD_HL		;24H/25Hにプリロード(BUSY待ち込み)

	;flagパルスリセット(1ショット)→ run-only に戻す
	PUSH	DE
	LD	D,TA_REG_CTRL
	LD	E,TA_CTRL_RUN_RESET_A
	CALL	OPN_WR_RD
	LD	D,TA_REG_CTRL
	LD	E,TA_CTRL_RUN_POLL
	CALL	OPN_WR_RD
	POP	DE

	CALL	RB_FILL_OPPORTUNISTIC	;polling前にSD補充

.poll:	IN	A,(OPN_ADDR)		;ステータス読み(bit0=Timer A overflow)
	AND	TA_STAT_FLAG_A_MASK
	JR	Z,.poll

	JR	.LOOP

;-------------------------------------------------
;CALC_TA_CHUNK / MUL_DE_322 / TA_LOAD_HL は VGMIRQ と同一
;-------------------------------------------------
CALC_TA_CHUNK:
	LD	A,D
	CP	MAX_CHUNK_HI
	JR	C,.SHORT
	JR	NZ,.LONG
	LD	A,E
	CP	MAX_CHUNK_LO
	JR	C,.SHORT
.LONG:
	LD	BC,MAX_SAMPLES_PER_CHUNK
	LD	HL,NA_MAX_CHUNK
	PUSH	HL
	LD	HL,0
	LD	A,E
	SUB	C
	LD	L,A
	LD	A,D
	SBC	A,B
	LD	H,A
	EX	DE,HL
	POP	HL
	RET

.SHORT:
	LD	B,D
	LD	C,E
	CALL	MUL_DE_322
	PUSH	HL
	LD	HL,1024
	POP	DE
	OR	A
	SBC	HL,DE
	LD	A,H
	OR	A
	JR	NZ,.OK
	LD	A,L
	OR	A
	JR	NZ,.OK
	LD	HL,1
.OK:
	LD	DE,0
	RET

MUL_DE_322:
	LD	H,D
	LD	L,E
	PUSH	DE
	SRL	D
	RR	E
	SRL	D
	RR	E
	ADD	HL,DE
	POP	DE
	PUSH	DE
	SRL	D
	RR	E
	SRL	D
	RR	E
	SRL	D
	RR	E
	SRL	D
	RR	E
	SRL	D
	RR	E
	SRL	D
	RR	E
	SRL	D
	RR	E
	ADD	HL,DE
	POP	DE
	RET

;-------------------------------------------------
;TA_LOAD_HL - 24H/25HへTimer A 10bitプリロードを書く(BUSY待ち込み)
; IN HL = プリロード値(0..1023)
; 高位 = HL >> 2 (8bit), 低位 = HL & 3
;-------------------------------------------------
TA_LOAD_HL:
	PUSH	BC
	PUSH	DE
	PUSH	HL
	PUSH	AF
	LD	C,L			;Cにオリジナル低位を退避(後で &3 する)
	;高位 = HL >> 2
	SRL	H
	RR	L
	SRL	H
	RR	L
	LD	D,TA_REG_HI
	LD	E,L
	CALL	OPN_WR_RD
	;低位2bit
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

;-------------------------------------------------
;TA_STOP_POLL - Timer A停止+flagクリア(BUSY待ち込み)
;-------------------------------------------------
TA_STOP_POLL:
	PUSH	DE
	LD	D,TA_REG_CTRL
	LD	E,TA_CTRL_STOP_RESET
	CALL	OPN_WR_RD
	LD	D,TA_REG_CTRL
	LD	E,0
	CALL	OPN_WR_RD
	POP	DE
	RET

;-------------------------------------------------
;RB_FILL_OPPORTUNISTIC - HALT(polling)前にSD補充
;-------------------------------------------------
RB_FILL_OPPORTUNISTIC:
	LD	HL,(RB_CNT)
	LD	DE,RBUF_HIWATER
	OR	A
	SBC	HL,DE
	RET	NC
	LD	A,(FILL_BURSTV)
	OR	A
	RET	Z
	LD	B,A
.lp:	CALL	RB_TRYFILL1
	JR	NC,.done
	DJNZ	.lp
.done:	RET

;-------------------------------------------------
;リングバッファ(VGMIRQと同じ)
;-------------------------------------------------
RB_INIT:
	LD	HL,RBUF
	LD	(RB_RDP),HL
	LD	(RB_WRP),HL
	LD	HL,0
	LD	(RB_CNT),HL
	XOR	A
	LD	(RB_EOF),A
	RET

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

RB_GET:
	LD	HL,(RB_CNT)
	LD	A,H
	OR	L
	SCF
	RET	Z
	LD	HL,(RB_RDP)
	LD	B,(HL)
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
	LD	A,B
	OR	A
	RET

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
	JR	NC,.NO
	CALL	STRM_READ
	JR	C,.EOF
	CALL	RB_PUT
	SCF
	RET
.EOF:	LD	A,0FFH
	LD	(RB_EOF),A
.NO:	OR	A
	RET

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
;PLAY_FILE - OPEN→ヘッダ解析→プリフィル→PLAY(IRQ_SETUPなし)
;=================================================
PLAY_FILE:
	LD	HL,PLAYNAME
	CALL	STRM_OPEN
	JR	C,.nf
	LD	(PLAYSP),SP
	CALL	RB_INIT
	CALL	PARSE_HDR
	CALL	RB_PREFILL
	;念のため Timer A を停止状態にしておく(N-BASIC 起動直後の状態保証)
	CALL	TA_STOP_POLL
	JP	PLAY
.nf:	LD	HL,MSG_NF
	CALL	PUTS
	RET

;=================================================
;BUILD_LIST / GET_NTH_VGM / IS_VGM / READ_NUM / PRDEC / PUTS
;以下 VGMIRQ と同じ
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

READ_NUM:
	LD	HL,0
.k:	PUSH	HL
	CALL	KEYWAIT
	POP	HL
	CP	CR
	JR	NZ,.chk
	LD	A,CR
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
IDENT:	DB	"Vgm "
TBL9X:	DB	4,4,5,10,1,4
MSG_HDR:	DB	CR,LF,"-- VGM (POLL) --",CR,LF,00H
MSG_COLON:	DB	": ",00H
MSG_PROMPT:	DB	CR,LF,"NO(0=END)? ",00H
VGMEXT:		DB	"VGM"
MSG_NF:		DB	CR,LF,"NOT FOUND",CR,LF,00H
MSG_NOTVGM:	DB	CR,LF,"NOT VGM",CR,LF,00H
MSG_BADHDR:	DB	CR,LF,"BAD HEADER",CR,LF,00H
MSG_BADCMD:	DB	CR,LF,"BAD COMMAND",CR,LF,00H
MSG_END:	DB	CR,LF,"VGM END",CR,LF,00H

;-------------------------------------------------
SAVSP:		DS	2
BLKSZ:		DS	4
RBUF:		DS	RBUF_SIZE
RBUF_END	EQU	$
RB_RDP:		DS	2
RB_WRP:		DS	2
RB_CNT:		DS	2
RB_EOF:		DS	1
PLAYSP:		DS	2
LISTCNT:	DS	1
VGMCNT:		DS	1
TARGETK:	DS	1
OPNREG:		DS	1
OPNDAT:		DS	1
FILECNT:	DS	1
LISTBUF:	DS	MAXFILES*0DH
PLAYNAME:	DS	0DH

STACK:		DS	256
STACK_TOP	EQU	$

	END
