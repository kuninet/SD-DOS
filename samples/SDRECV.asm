;=================================================
;SDRECV - YMODEM file receiver (8251 Ch1 interrupt + ring + STRM_WRITE)
;=================================================
;Receives a YMODEM(batch) transfer from host (lrzsz `sb -k file`) and
;writes payload to SD via SD-DOS write streaming API (6014/6017/601A).
;
;Hardware: kuninet/PC8001ext232C (8251 x2)
;  Ch1: 0C0H=data, 0C1H=command/status, mode-2 vector = 8008H
;
;Usage:
;  LOAD "SDRECV.CMT"
;  monitor: G9000
;  host: sb -k file.vgm </dev/tty.usbserial-... >/dev/tty.usbserial-...
;
;Protocol notes:
;  - CRC mode only (we keep sending 'C' until first SOH/STX)
;  - SOH = 128B block, STX = 1024B block
;  - block 0 = filename + size in ASCII decimal (parsed up to 4 bytes)
;  - per block: payload + 2-byte CRC-16/XMODEM (poly 1021H, init 0)
;  - last data block padded by sender; we cap writes by REMAIN
;  - EOT -> ACK -> send 'C' -> recv empty block 0 (filename="") -> ACK -> FCLOSE
;=================================================

;----- 8251 -----
CH1_DATA	EQU	0C0H
CH1_CMD		EQU	0C1H
RX_RDY		EQU	02H
TX_RDY		EQU	01H
SIO_ERR_MASK	EQU	38H
VEC_CH1		EQU	8008H

MODE_INST	EQU	4EH		;async x16 8N1
CMD_RXEN	EQU	15H		;TxEN+RxE+ER
CMD_RXOFF	EQU	10H		;ER only

;----- YMODEM -----
SOH		EQU	01H
STX		EQU	02H
EOT		EQU	04H
ACK		EQU	06H
NAK		EQU	15H
CAN		EQU	18H
YC		EQU	'C'		;43H = request CRC mode

;----- SD-DOS write API (PR #65) -----
STRM_CREATE	EQU	6014H
STRM_WRITE	EQU	6017H
STRM_FCLOSE	EQU	601AH

;----- N-BASIC -----
BASIC		EQU	0081H
CR		EQU	0DH
LF		EQU	0AH

;----- buffer layout -----
RBUF_ADR	EQU	0A000H		;256B ring (8-bit index wrap)
RBUF_HI		EQU	0A0H
BLKBUF		EQU	0A200H		;up to 1024B payload (STX)

	ORG	09000H

	JP	START

;-------------------------------------------------
START:
	DI
	LD	(SAVSP),SP
	LD	SP,STACK_TOP
	LD	HL,MSG_HEAD
	CALL	PUTS
	CALL	INSTALL_ISR
	EI

	CALL	YMAIN			;run the YMODEM state machine

	CALL	PUTS_CRLF
	LD	HL,MSG_DONE
	CALL	PUTS

QUIT:
	DI
	CALL	UNINSTALL_ISR
	LD	SP,(SAVSP)
	EI
	JP	BASIC

;=================================================
;YMODEM state machine
;=================================================
YMAIN:
	;----- Phase 1: receive header block (block 0) -----
	XOR	A
	LD	(F_OPENED),A
	LD	(SEEN_HEADER),A
.HDR_RETRY:
	CALL	YM_WAIT_FRAME		;A=marker (sends 'C' until something arrives)
	CP	CAN
	JP	Z,YM_ABORT_CAN
	CP	EOT			;weird before header - ACK and keep waiting
	JR	NZ,.HDR_CHK
	LD	B,ACK
	CALL	PUTC
	JR	.HDR_RETRY
.HDR_CHK:
	CP	SOH
	JR	Z,.HDR_OK
	CP	STX
	JR	NZ,.HDR_RETRY		;unknown, ignore and wait again
.HDR_OK:
	CALL	YM_RECV_PAYLOAD		;CY=0 OK, CY=1 bad
	JR	C,.HDR_NAK
	LD	A,(BLK_SEQ)
	OR	A			;must be seq 0
	JR	NZ,.HDR_NAK
	;parse filename + size from BLKBUF
	CALL	YM_PARSE_HEADER
	;empty filename in first header? treat as end-of-batch (nothing to do)
	LD	A,(FNAME)
	OR	A
	JR	Z,.HDR_EMPTY
	;create file
	LD	HL,FNAME
	CALL	STRM_CREATE
	LD	A,01H
	LD	(F_OPENED),A
	;print receiving info
	LD	HL,MSG_RECV
	CALL	PUTS
	LD	HL,FNAME
	CALL	PUTS
	CALL	PUTS_CRLF
	;ACK and request data blocks
	LD	B,ACK
	CALL	PUTC
	LD	B,YC
	CALL	PUTC
	JR	.DATA_INIT
.HDR_EMPTY:
	;empty filename = end of batch (no actual transfer)
	LD	B,ACK
	CALL	PUTC
	RET
.HDR_NAK:
	LD	B,NAK
	CALL	PUTC
	JR	.HDR_RETRY

.DATA_INIT:
	LD	A,01H			;expected seq = 1
	LD	(EXP_SEQ),A

	;----- Phase 2: data blocks -----
YM_DATA_LOOP:
	CALL	YM_WAIT_FRAME		;A=marker (no 'C' once data started - but keep loose)
	CP	EOT
	JP	Z,YM_EOT
	CP	CAN
	JP	Z,YM_ABORT_CAN
	CP	SOH
	JR	Z,.DOK
	CP	STX
	JR	NZ,YM_DATA_LOOP		;unknown, ignore
.DOK:
	CALL	YM_RECV_PAYLOAD
	JR	C,.D_NAK
	;sequence check
	LD	A,(BLK_SEQ)
	LD	HL,EXP_SEQ
	CP	(HL)
	JR	Z,.D_OK
	;maybe duplicate (sender re-sent previous)
	DEC	(HL)
	CP	(HL)
	INC	(HL)
	JR	Z,.D_DUP
	;sequence way off - NAK
	JR	.D_NAK
.D_OK:
	CALL	YM_WRITE_BLOCK		;write up to REMAIN bytes
	LD	HL,EXP_SEQ
	INC	(HL)
	LD	B,ACK
	CALL	PUTC
	JR	YM_DATA_LOOP
.D_DUP:
	LD	B,ACK
	CALL	PUTC
	JR	YM_DATA_LOOP
.D_NAK:
	LD	B,NAK
	CALL	PUTC
	JR	YM_DATA_LOOP

YM_EOT:
	LD	B,ACK
	CALL	PUTC
	LD	B,YC
	CALL	PUTC
	;recv trailing block 0 (empty)
.EOT_W:	CALL	YM_WAIT_FRAME
	CP	SOH
	JR	NZ,.EOT_W
	CALL	YM_RECV_PAYLOAD
	;ignore content; ACK regardless
	LD	B,ACK
	CALL	PUTC
	;close file
	LD	A,(F_OPENED)
	OR	A
	CALL	NZ,STRM_FCLOSE
	XOR	A
	LD	(F_OPENED),A
	RET

YM_ABORT_CAN:
	LD	HL,MSG_CAN
	CALL	PUTS
	LD	A,(F_OPENED)
	OR	A
	CALL	NZ,STRM_FCLOSE
	XOR	A
	LD	(F_OPENED),A
	RET

;=================================================
;YM_WAIT_FRAME: wait for next frame marker, periodically sending 'C'.
;  Each timeout window sends one 'C' until we get a byte.
;OUT A=received byte
;=================================================
YM_WAIT_FRAME:
.SEND:	LD	B,YC
	CALL	PUTC
.WAIT:	LD	HL,4000H		;coarse poll window
.W2:	CALL	CHECK_RX
	JR	NC,.GOT
	DEC	HL
	LD	A,H
	OR	L
	JR	NZ,.W2
	JR	.SEND
.GOT:	RET

;=================================================
;YM_RECV_PAYLOAD: receive seq + ~seq + N bytes payload + 2-byte CRC.
;IN  A = SOH or STX (caller already consumed it)
;OUT BLK_SEQ, BLKBUF filled, CY=0 OK / CY=1 bad (caller should NAK)
;Always drains the full frame so the ring stays in sync.
;=================================================
YM_RECV_PAYLOAD:
	CP	STX
	JR	Z,.STX
	LD	BC,128
	JR	.HDR
.STX:	LD	BC,1024
.HDR:	LD	(BLK_N),BC
	CALL	GETC
	LD	(BLK_SEQ),A
	CALL	GETC			;~seq
	LD	B,A
	LD	A,(BLK_SEQ)
	CPL
	CP	B
	LD	A,00H
	JR	Z,.HOK
	LD	A,0FFH
.HOK:	LD	(HDR_ERR),A
	;read payload, updating CRC in HL
	LD	HL,0			;CRC init
	LD	DE,BLKBUF
	LD	BC,(BLK_N)
.RDP:	CALL	GETC
	LD	(DE),A
	INC	DE
	CALL	CRC16_UPDATE
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.RDP
	PUSH	HL			;save computed
	CALL	GETC
	LD	D,A			;recvd hi
	CALL	GETC
	LD	E,A			;recvd lo
	POP	HL
	LD	A,(HDR_ERR)
	OR	A
	JR	NZ,.BAD
	LD	A,H
	CP	D
	JR	NZ,.BAD
	LD	A,L
	CP	E
	JR	NZ,.BAD
	OR	A			;CY<-0
	RET
.BAD:	SCF
	RET

;=================================================
;CRC16_UPDATE: HL = CRC ^= (A<<8); then 8 iterations of:
;  shift HL left; if carry out, HL ^= 1021H
;IN  HL=CRC, A=byte. OUT HL=new CRC. Preserves BC/DE.
;=================================================
CRC16_UPDATE:
	PUSH	BC
	XOR	H
	LD	H,A
	LD	B,8
.L:	ADD	HL,HL
	JR	NC,.NEXT
	LD	A,H
	XOR	10H
	LD	H,A
	LD	A,L
	XOR	21H
	LD	L,A
.NEXT:	DJNZ	.L
	POP	BC
	RET

;=================================================
;YM_PARSE_HEADER: parse block 0 payload into FNAME (uppercased, ASCIIZ)
;  and REMAIN (4 bytes little-endian) from the ASCII decimal size that
;  follows the filename's NUL terminator.
;IN  BLKBUF
;OUT FNAME, REMAIN
;=================================================
YM_PARSE_HEADER:
	LD	HL,BLKBUF
	LD	DE,FNAME
.N:	LD	A,(HL)
	OR	A
	JR	Z,.NEND
	CP	'a'
	JR	C,.STORE
	CP	'z'+1
	JR	NC,.STORE
	SUB	'a'-'A'
.STORE:	LD	(DE),A
	INC	DE
	INC	HL
	JR	.N
.NEND:	XOR	A
	LD	(DE),A			;ASCIIZ
	INC	HL			;skip the 0
	;clear REMAIN(4)
	LD	HL,REMAIN
	LD	B,4
.CL:	LD	(HL),0
	INC	HL
	DJNZ	.CL
	;parse digits
	LD	HL,BLKBUF
	CALL	SKIP_NAME		;advance HL past filename + 0
.SZ:	LD	A,(HL)
	CP	'0'
	JR	C,.SEND
	CP	'9'+1
	JR	NC,.SEND
	SUB	'0'
	PUSH	HL
	PUSH	AF
	CALL	REMAIN_MUL10
	POP	AF
	CALL	REMAIN_ADD_A
	POP	HL
	INC	HL
	JR	.SZ
.SEND:	RET

SKIP_NAME:
.L:	LD	A,(HL)
	INC	HL
	OR	A
	JR	NZ,.L
	RET

;REMAIN *= 10  (REMAIN = (REMAIN<<2 + REMAIN)<<1)
REMAIN_MUL10:
	CALL	REMAIN_COPY_TMP		;TEMP = REMAIN
	CALL	REMAIN_SHL		;REMAIN <<= 1   (= 2*orig)
	CALL	REMAIN_SHL		;REMAIN <<= 1   (= 4*orig)
	CALL	REMAIN_ADD_TMP		;REMAIN += TEMP (= 5*orig)
	CALL	REMAIN_SHL		;REMAIN <<= 1   (= 10*orig)
	RET

REMAIN_COPY_TMP:
	LD	HL,REMAIN
	LD	DE,REM_TMP
	LD	BC,4
	LDIR
	RET

REMAIN_SHL:
	LD	HL,REMAIN
	OR	A			;CY<-0
	LD	B,4
.L:	LD	A,(HL)
	ADC	A,A
	LD	(HL),A
	INC	HL
	DJNZ	.L
	RET

REMAIN_ADD_TMP:
	LD	HL,REMAIN
	LD	DE,REM_TMP
	OR	A			;CY<-0
	LD	B,4
.L:	LD	A,(DE)
	ADC	A,(HL)
	LD	(HL),A
	INC	HL
	INC	DE
	DJNZ	.L
	RET

REMAIN_ADD_A:
	;REMAIN += A (zero-extended)
	PUSH	HL
	LD	HL,REMAIN
	ADD	A,(HL)
	LD	(HL),A
	JR	NC,.OUT
	INC	HL
	INC	(HL)
	JR	NZ,.OUT
	INC	HL
	INC	(HL)
	JR	NZ,.OUT
	INC	HL
	INC	(HL)
.OUT:	POP	HL
	RET

;REMAIN -= 1 (CY=1 if it would underflow - never called when REMAIN=0)
REMAIN_DEC:
	PUSH	HL
	LD	HL,REMAIN
	LD	A,(HL)
	SUB	1
	LD	(HL),A
	INC	HL
	LD	A,(HL)
	SBC	A,0
	LD	(HL),A
	INC	HL
	LD	A,(HL)
	SBC	A,0
	LD	(HL),A
	INC	HL
	LD	A,(HL)
	SBC	A,0
	LD	(HL),A
	POP	HL
	RET

;REMAIN == 0 ?  Z=1 if so
REMAIN_IS_ZERO:
	PUSH	HL
	LD	HL,REMAIN
	LD	A,(HL)
	INC	HL
	OR	(HL)
	INC	HL
	OR	(HL)
	INC	HL
	OR	(HL)
	POP	HL
	RET

;=================================================
;YM_WRITE_BLOCK: write BLKBUF[0..BLK_N-1] to SD, capped by REMAIN.
;Updates REMAIN.
;=================================================
YM_WRITE_BLOCK:
	LD	HL,BLKBUF
	LD	BC,(BLK_N)
.L:	CALL	REMAIN_IS_ZERO
	RET	Z
	LD	A,(HL)
	CALL	STRM_WRITE
	CALL	REMAIN_DEC
	INC	HL
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.L
	RET

;=================================================
;CHECK_RX: non-blocking ring read.
;OUT CY=0 + A=byte if available, CY=1 if empty.
;=================================================
CHECK_RX:
	LD	HL,RBUF_R
	LD	A,(RBUF_W)
	CP	(HL)
	JR	Z,.EMPTY
	LD	A,(HL)
	LD	H,RBUF_HI
	LD	L,A
	LD	A,(HL)			;data
	LD	HL,RBUF_R
	INC	(HL)
	OR	A			;CY<-0 (Z may follow if data=0; caller ignores Z)
	RET
.EMPTY:	SCF
	RET

;=================================================
;Vector + 8251 init (same as PR #69 skeleton)
;=================================================
INSTALL_ISR:
	LD	A,CMD_RXOFF
	OUT	(CH1_CMD),A
	LD	HL,(VEC_CH1)
	LD	(SAVED_VEC),HL
	LD	HL,ISR
	LD	(VEC_CH1),HL
	XOR	A
	LD	(RBUF_W),A
	LD	(RBUF_R),A
	LD	(RBUF_OVR),A
	XOR	A
	OUT	(CH1_CMD),A
	OUT	(CH1_CMD),A
	OUT	(CH1_CMD),A
	LD	A,40H
	OUT	(CH1_CMD),A
	LD	A,MODE_INST
	OUT	(CH1_CMD),A
	LD	A,CMD_RXEN
	OUT	(CH1_CMD),A
	RET

UNINSTALL_ISR:
	LD	A,CMD_RXOFF
	OUT	(CH1_CMD),A
	LD	HL,(SAVED_VEC)
	LD	(VEC_CH1),HL
	RET

ISR:
	PUSH	AF
	PUSH	BC
	PUSH	HL
	IN	A,(CH1_CMD)
	LD	B,A
	AND	SIO_ERR_MASK
	JR	Z,.NOERR
	LD	A,CMD_RXEN
	OUT	(CH1_CMD),A
.NOERR:	LD	A,B
	AND	RX_RDY
	JR	Z,.EXIT
	IN	A,(CH1_DATA)
	LD	C,A
	LD	A,(RBUF_W)
	INC	A
	LD	HL,RBUF_R
	CP	(HL)
	JR	Z,.OVR
	LD	H,RBUF_HI
	LD	L,A
	DEC	L
	LD	(HL),C
	LD	(RBUF_W),A
	JR	.EXIT
.OVR:	LD	HL,RBUF_OVR
	INC	(HL)
.EXIT:	POP	HL
	POP	BC
	POP	AF
	EI
	RETI

;=================================================
;Blocking GETC, used by the YMODEM parser.
;=================================================
GETC:
	PUSH	HL
.WAIT:	LD	HL,RBUF_R
	LD	A,(RBUF_W)
	CP	(HL)
	JR	Z,.WAIT
	LD	A,(HL)
	LD	H,RBUF_HI
	LD	L,A
	LD	A,(HL)
	LD	HL,RBUF_R
	INC	(HL)
	POP	HL
	RET

PUTC:
.WAIT:	IN	A,(CH1_CMD)
	AND	TX_RDY
	JR	Z,.WAIT
	LD	A,B
	OUT	(CH1_DATA),A
	RET

;=================================================
;PUTS: HL = ASCIIZ string. CR -> CR+LF on display.
;=================================================
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

PUTS_CRLF:
	LD	A,CR
	RST	18H
	LD	A,LF
	RST	18H
	RET

;=================================================
;Messages
;=================================================
MSG_HEAD:	DB	"-- SDRECV YMODEM --",CR,0
MSG_RECV:	DB	"RECV: ",0
MSG_DONE:	DB	"DONE",CR,0
MSG_CAN:	DB	CR,"CANCELED",CR,0

;=================================================
;Work area
;=================================================
SAVED_VEC:	DW	0
SAVSP:		DW	0
RBUF_W:		DB	0
RBUF_R:		DB	0
RBUF_OVR:	DB	0

BLK_SEQ:	DB	0
HDR_ERR:	DB	0		;FFH = ~seq mismatch
BLK_N:		DW	0
EXP_SEQ:	DB	0
F_OPENED:	DB	0
SEEN_HEADER:	DB	0
REMAIN:		DS	4		;bytes still to write
REM_TMP:	DS	4
FNAME:		DS	16		;"NAME.EXT" + 0 (max 12+1)

		DS	64
STACK_TOP	EQU	$
