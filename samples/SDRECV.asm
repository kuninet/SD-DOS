;=================================================
;SDRECV - シリアル受信骨格(8251 Ch1, 割り込み駆動+リングバッファ)
;=================================================
;・kuninet/PC8001ext232C(8251×2)前提
;  Ch1: 0C0H=データ, 0C1H=コマンド/ステータス
;  受信割り込み: モード2ベクタ08H→ 8008H(N-BASIC側ベクタ書換で奪う)
;・本サンプルはYMODEM受信を載せる前の骨格(ポーリング送信+割込み受信+リング)
;・echo demo: 母艦(`tio /dev/tty.usbserial-...` 等)から打った文字を画面に表示、
;  'Q'/'q'で BASIC へ復帰
;・使い方: LOAD "SDRECV.CMT" → 機械語モニタ G9000(終了は文字 'Q')
;・配線: 9600 8N1 を想定。8251 モード/コマンド値は実機で要再確認
;=================================================

CH1_DATA	EQU	0C0H
CH1_CMD		EQU	0C1H
RX_RDY		EQU	02H		;0C1H bit1
TX_RDY		EQU	01H		;0C1H bit0
SIO_ERR_MASK	EQU	38H		;PE(bit3)|OE(bit4)|FE(bit5)

VEC_CH1		EQU	8008H		;モード2 Ch1ベクタアドレス

;8251 モード命令: 非同期 ×16, 8bit, parity none, 1stop = 4EH
MODE_INST	EQU	4EH
;8251 コマンド: RxE(bit2)+TxEN(bit0)+ER(bit4) = 15H
CMD_RXEN	EQU	15H
;8251 コマンド: 受信停止+ER + ER = 10H
CMD_RXOFF	EQU	10H

BASIC		EQU	0081H
CR		EQU	0DH
LF		EQU	0AH

RBUF_ADR	EQU	0A000H		;リングバッファは256B境界(L=indexで完結)
RBUF_HI		EQU	0A0H		;HIGH(RBUF_ADR)

	ORG	09000H

	JP	START

START:
	DI
	LD	(SAVSP),SP
	LD	SP,STACK_TOP
	LD	HL,MSG_HEAD
	CALL	PUTS
	CALL	INSTALL_ISR		;ベクタ書換+8251初期化
	EI

ECHO_LOOP:
	CALL	GETC			;A=受信1バイト
	CP	'Q'
	JR	Z,QUIT
	CP	'q'
	JR	Z,QUIT
	LD	B,A			;画面表示+エコー
	CALL	PUT_CHAR
	CALL	PUTC
	JR	ECHO_LOOP

QUIT:
	DI
	CALL	UNINSTALL_ISR
	LD	HL,MSG_BYE
	CALL	PUTS
	LD	SP,(SAVSP)
	EI
	JP	BASIC

;-------------------------------------------------
;ベクタ書換+8251初期化(DI状態で呼ぶこと)
;-------------------------------------------------
INSTALL_ISR:
	LD	A,CMD_RXOFF		;受信を一旦止める
	OUT	(CH1_CMD),A
	LD	HL,(VEC_CH1)		;既存ベクタを退避
	LD	(SAVED_VEC),HL
	LD	HL,ISR			;自前ISRを設定
	LD	(VEC_CH1),HL
	XOR	A			;リングを空に
	LD	(RBUF_W),A
	LD	(RBUF_R),A
	LD	(RBUF_OVR),A
	;8251 を内部リセット(0×3+40H)→モード→コマンドの順
	XOR	A
	OUT	(CH1_CMD),A
	OUT	(CH1_CMD),A
	OUT	(CH1_CMD),A
	LD	A,40H			;internal reset
	OUT	(CH1_CMD),A
	LD	A,MODE_INST
	OUT	(CH1_CMD),A
	LD	A,CMD_RXEN
	OUT	(CH1_CMD),A
	RET

;-------------------------------------------------
;ベクタ復元+8251受信停止(DI状態で呼ぶこと)
;-------------------------------------------------
UNINSTALL_ISR:
	LD	A,CMD_RXOFF
	OUT	(CH1_CMD),A
	LD	HL,(SAVED_VEC)
	LD	(VEC_CH1),HL
	RET

;-------------------------------------------------
;ISR: 8251 Ch1受信割り込み
; ・ステータス確認→データ取得→ring末尾へ格納
; ・エラービットが立っていれば ER(CMD bit4)で確実にクリア
; ・満杯時はデータを捨てて RBUF_OVR++(古い側を活かす)
;-------------------------------------------------
ISR:
	PUSH	AF
	PUSH	BC
	PUSH	HL
	IN	A,(CH1_CMD)
	LD	B,A			;Bにステータス保存
	AND	SIO_ERR_MASK		;エラー?
	JR	Z,.NOERR
	LD	A,CMD_RXEN		;ERビットでクリア(同じ値でER再発行)
	OUT	(CH1_CMD),A
.NOERR:
	LD	A,B
	AND	RX_RDY
	JR	Z,.EXIT			;spurious
	IN	A,(CH1_DATA)		;受信データ
	LD	C,A
	LD	A,(RBUF_W)		;新Wを計算
	INC	A
	LD	HL,RBUF_R		;新W == R ならoverflow
	CP	(HL)
	JR	Z,.OVR
	;格納: ring[oldW] = C, RBUF_W = newW
	LD	H,RBUF_HI
	LD	L,A
	DEC	L			;oldW
	LD	(HL),C
	LD	(RBUF_W),A
	JR	.EXIT
.OVR:	LD	HL,RBUF_OVR		;捨てた回数を記録
	INC	(HL)
.EXIT:
	POP	HL
	POP	BC
	POP	AF
	EI
	RETI

;-------------------------------------------------
;GETC: リングから1バイト取り出す(空ならビジー待ち)
;OUT A=取り出した1バイト
;-------------------------------------------------
GETC:
	PUSH	HL
.WAIT:	LD	HL,RBUF_R
	LD	A,(RBUF_W)
	CP	(HL)
	JR	Z,.WAIT			;空
	;取得: A=R, data=ring[R], R++
	LD	A,(HL)
	LD	H,RBUF_HI
	LD	L,A
	LD	A,(HL)			;data
	LD	HL,RBUF_R
	INC	(HL)			;R++
	POP	HL
	RET

;-------------------------------------------------
;PUTC: 1バイトをCh1へ送信(TxRDYビジー待ち)
;IN  B=送信1バイト
;-------------------------------------------------
PUTC:
.WAIT:	IN	A,(CH1_CMD)
	AND	TX_RDY
	JR	Z,.WAIT
	LD	A,B
	OUT	(CH1_DATA),A
	RET

;-------------------------------------------------
;PUT_CHAR: B(=送信値の控え) または A を画面1文字表示
;・CR は CR+LF に展開
;-------------------------------------------------
PUT_CHAR:
	LD	A,B
	CP	CR
	JR	NZ,.NORM
	RST	18H			;CR
	LD	A,LF
.NORM:	RST	18H
	RET

;-------------------------------------------------
;PUTS: HL=00H終端文字列を画面に表示(CR→CR+LF)
;-------------------------------------------------
PUTS:
.L:	LD	A,(HL)
	OR	A
	RET	Z
	CP	CR
	JR	NZ,.S
	RST	18H
	LD	A,LF
.S:	RST	18H
	INC	HL
	JR	.L

;-------------------------------------------------
;メッセージ
;-------------------------------------------------
MSG_HEAD:	DB	"-- SDRECV ECHO --",CR
		DB	"PRESS KEYS ON HOST. Q=END",CR,0
MSG_BYE:	DB	CR,"BYE",CR,0

;-------------------------------------------------
;ワーク
;-------------------------------------------------
SAVED_VEC:	DW	0
SAVSP:		DW	0
RBUF_W:		DB	0		;書き込みindex(ISR側)
RBUF_R:		DB	0		;読み出しindex(GETC側)
RBUF_OVR:	DB	0		;オーバーラン回数(参考)

		DS	64
STACK_TOP	EQU	$

;リングバッファ本体は別途 0A000H に置く(HIGH/LOW を index で扱う)
