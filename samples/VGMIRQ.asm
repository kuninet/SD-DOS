;=================================================
; VGMIRQ - VGM player (interrupt-driven via YM2203 Timer A)
;=================================================
; - Streams *.VGM from SD via streaming API and feeds YM2203 (80H/81H)
;   and PSG (0A0H/0A1H).
; - Wait commands are driven by YM2203 Timer A under Z80 IM 2.
; - PC-8001 keeps I=80H; IM2 vector table lives at $8000..$80FF in RAM
;   (placed there by N-BASIC at boot). On entry we save the original
;   2-byte entry at $8000 + (IVR_FMTAV), overwrite it with ISR_FMTA,
;   and restore it on exit. The 232C 8251 entries at $8008/$800A are
;   not touched, so serial IRQ keeps working.
; - Launch: LOAD "VGMIRQ.CMT" :  (CD if needed) :  monitor G9000
;   List .VGM in CWD -> number+Enter to play -> 0+Enter to quit.
; - POKE points:
;   9003H = IVR_FMTAV     vector byte for FM Timer A IRQ
;   9004H = FILL_BURSTV   max ring-buffer refill per HALT
;   9005H = TA_NA_LO_DBG  (reserved for debugging, unused by player)
; - See docs/vgm/{commands,header,sound-io,README}.md for format details.
;=================================================

STRM_OPEN	EQU	6005H
STRM_READ	EQU	6008H
STRM_CLOSE	EQU	600BH
STRM_DIRLIST	EQU	600EH

OPN_ADDR	EQU	80H
OPN_DATA	EQU	81H
PSG_ADDR	EQU	0A0H
PSG_DATA	EQU	0A1H

CR		EQU	0DH
LF		EQU	0AH
BASIC		EQU	0081H
KEYWAIT		EQU	0F75H
MAXFILES	EQU	40H

; --- YM2203 Timer A registers (see docs/vgm/sound-io.md / YM2203 datasheet) ---
; 27H bit layout: bit0=LoadA, bit1=LoadB, bit2=IRQEN A, bit3=IRQEN B,
;                 bit4=ResetA, bit5=ResetB, bit7:6=CH3 mode
TA_REG_HI	EQU	24H
TA_REG_LO	EQU	25H
TA_REG_CTRL	EQU	27H
TA_CTRL_RUN_IRQEN	EQU	00000101B	; LoadA=1, IRQEN A=1
TA_CTRL_STOP_RESET	EQU	00010000B	; ResetA=1
TA_FLAG_RESET_A_MASK	EQU	00010000B	; bit4

; --- VGM/sample to Timer A tick conversion (Phase 0 calibrated) ---
; 1 sample = 1/44100s ~= 22.676us
; YM2203 Timer A 1 tick = 72/master_clock; assume 4MHz -> 18us
; ticks_per_sample = 22.676 / 18 ~= 1.260
; *256 fixed point: round(1.260 * 256) = 322
TICKS_PER_SAMPLE_X256	EQU	322
MAX_SAMPLES_PER_CHUNK	EQU	512
MAX_CHUNK_HI	EQU	02H		; high byte of 512
MAX_CHUNK_LO	EQU	00H		; low  byte of 512
; NA = 1024 - (MAX_SAMPLES_PER_CHUNK * TICKS_PER_SAMPLE_X256 / 256)
;    = 1024 - 645 = 379
NA_MAX_CHUNK	EQU	379

; --- IM2 vector table (lives in $8000-page RAM under N-BASIC) ---
IVT_PAGE	EQU	80H
IVR_FMTA_DEFAULT	EQU	04H		; one of INT4..7 (Phase 0)
; effective entry address is computed at run time from IVR_FMTAV (POKE-able)

; --- Ring buffer ---
; Sized so STACK_TOP stays below ~E12E (N-BASIC high work area).
; Larger code than VGMPLAY (ISR/Timer A logic) forces a slightly
; smaller ring than VGMPLAY's 4800H. Adjust if code shrinks.
RBUF_SIZE	EQU	4500H		; ~17.25KB
INITFILL	EQU	2000H		; pre-fill 8KB before play
RBUF_HIWATER	EQU	RBUF_SIZE - 0100H
FILL_BURST	EQU	04H

	ORG	9000H

	JP	START			; 9000H exec entry (monitor G9000)
IVR_FMTAV:	DB	IVR_FMTA_DEFAULT	; 9003H POKE: FM Timer A IRQ vector byte
FILL_BURSTV:	DB	FILL_BURST	; 9004H POKE: max refill calls per HALT
TA_NA_LO_DBG:	DB	0		; 9005H reserved (debug)

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
	JP	Z,BASIC			; 0 -> quit
	LD	A,(LISTCNT)
	CP	L
	JR	C,MENU			; out-of-range
	LD	A,L
	CALL	GET_NTH_VGM
	JR	C,MENU
	CALL	PLAY_FILE
	JR	MENU

;-------------------------------------------------
; Normal end (end-cmd or EOF)
;-------------------------------------------------
DONE:
	LD	SP,(PLAYSP)
	CALL	IRQ_TEARDOWN
	CALL	STRM_CLOSE
	LD	HL,MSG_END
	CALL	PUTS
	RET

;-------------------------------------------------
; Abort with message  IN HL=msg
;-------------------------------------------------
ABORT:
	LD	SP,(PLAYSP)
	PUSH	HL
	CALL	IRQ_TEARDOWN
	CALL	STRM_CLOSE
	POP	HL
	CALL	PUTS
	RET

;-------------------------------------------------
; BREAK abort  (called via JP from check)
;-------------------------------------------------
ABORT_BREAK:
	LD	HL,MSG_BRK
	JP	ABORT

;-------------------------------------------------
; Header parse (subset of docs/vgm/header.md)
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
	CALL	SKIP			; 04H-07H EOF offset (skip)
	CALL	GETB			; 08H-0BH version (BCD)
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
	LD	DE,0028H		; skip 0CH-33H
	CALL	SKIP
	CALL	GETB			; 34H-37H data offset
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

.OLD:	LD	DE,0034H		; 1.00/1.01 fixed at 40H
	JP	SKIP

.NOTVGM:	LD	HL,MSG_NOTVGM
	JP	ABORT
.BADHDR:	LD	HL,MSG_BADHDR
	JP	ABORT

;-------------------------------------------------
; Play loop (docs/vgm/commands.md)
;-------------------------------------------------
PLAY:
.LOOP:	CALL	CHECK_BREAK
	CALL	GETB
	CP	66H			; end
	JP	Z,DONE
	CP	55H			; YM2203
	JR	Z,.OPN
	CP	0A0H			; PSG
	JR	Z,.PSG
	CP	61H			; wait n samples
	JR	Z,.W61
	CP	62H			; wait 735
	JR	Z,.W62
	CP	63H			; wait 882
	JR	Z,.W63
	LD	C,A
	AND	0F0H
	CP	70H			; 70-7F short wait
	JR	Z,.W7X
	CP	80H			; 80-8F YM2612 DAC+wait (ignored)
	JR	Z,.LOOP
	LD	A,C
	JP	SKIP_CMD

.OPN:	CALL	GETB
	LD	(OPNREG),A
	CALL	GETB
	LD	(OPNDAT),A
.BUSY:	IN	A,(OPN_ADDR)		; BUSY=bit7
	RLCA
	JR	C,.BUSY
	LD	A,(OPNREG)
	OUT	(OPN_ADDR),A
	LD	A,(OPNREG)		; small delay (dummy read register selected)
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
	CALL	WAIT_DE_HALT
	JP	PLAY.LOOP
.W62:	LD	DE,735			; 1/60s
	CALL	WAIT_DE_HALT
	JP	PLAY.LOOP
.W63:	LD	DE,882			; 1/50s
	CALL	WAIT_DE_HALT
	JP	PLAY.LOOP
.W7X:	LD	A,C
	AND	0FH
	INC	A
	LD	E,A
	LD	D,0
	CALL	WAIT_DE_HALT
	JP	PLAY.LOOP

;-------------------------------------------------
; Skip unsupported commands (docs/vgm/commands.md table)
;-------------------------------------------------
SKIP_CMD:
	CP	30H
	JR	C,.BAD
	CP	40H			; 30-3F 1B
	JR	C,.S1
	CP	4FH
	JR	C,.BAD
	CP	51H			; 4F,50 1B
	JR	C,.S1
	CP	60H			; 51-5F 2B
	JR	C,.S2
	CP	64H			; 64 3B
	JR	Z,.S3
	CP	67H			; 67 data block
	JR	Z,.BLK
	CP	90H			; 60,65,68-6F unknown
	JR	C,.BAD
	CP	96H			; 90-95 DAC stream
	JR	C,.S9X
	CP	0A1H			; 96-A0 unknown
	JR	C,.BAD
	CP	0C0H			; A1-BF 2B
	JR	C,.S2
	CP	0E0H			; C0-DF 3B
	JR	C,.S3
.S4:	CALL	GETB			; E0-FF 4B
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

.BLK:	CALL	GETB			; 66H (compat byte)
	CALL	GETB			; block type
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

;-------------------------------------------------
; SKIP DE bytes from stream
;-------------------------------------------------
SKIP:	LD	A,D
	OR	E
	RET	Z
	CALL	GETB
	DEC	DE
	JR	SKIP

;-------------------------------------------------
; GETB - one byte from ring buffer (EOF treated as end-of-play)
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

;-------------------------------------------------
; CHECK_BREAK - poll STOP key (non-blocking-ish via KEYWAIT? VGMPLAY's
; original uses no break check inside the play loop; we leave a stub
; that returns immediately. STOP key handling is delegated to N-BASIC
; ISR (still active because $8008/$800A are untouched).
;-------------------------------------------------
CHECK_BREAK:
	RET

;=================================================
; WAIT_DE_HALT - sleep for DE samples using Timer A IRQ
; IN: DE = sample count
;=================================================
WAIT_DE_HALT:
.LOOP:	LD	A,D
	OR	E
	RET	Z

	CALL	CALC_TA_CHUNK		; OUT: BC=consumed, HL=NA, DE=remaining

	CALL	TA_LOAD_HL		; write 24H/25H

	XOR	A
	LD	(TA_TICK),A

	CALL	TA_START		; 27H <- LoadA|IRQEN A

	CALL	RB_FILL_OPPORTUNISTIC	; refill before sleeping (BC = chunk size)

	EI
	HALT				; wake on Timer A IRQ

	LD	A,(TA_TICK)
	OR	A
	JR	Z,.WAGAIN
	JR	.LOOP
.WAGAIN:
	EI
	HALT
	JR	.LOOP

;-------------------------------------------------
; CALC_TA_CHUNK
;  IN  DE = remaining samples (16bit)
;  OUT BC = samples consumed this chunk
;      HL = Timer A 10-bit preload (NA)
;      DE = remaining - BC
;-------------------------------------------------
CALC_TA_CHUNK:
	; if DE >= MAX_SAMPLES_PER_CHUNK -> long branch
	LD	A,D
	CP	MAX_CHUNK_HI
	JR	C,.SHORT
	JR	NZ,.LONG
	LD	A,E
	CP	MAX_CHUNK_LO
	JR	C,.SHORT
.LONG:
	; BC = MAX, HL = NA_MAX_CHUNK, DE -= BC
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
	EX	DE,HL			; DE = remaining-BC
	POP	HL
	RET

.SHORT:
	; tick = DE * TICKS_PER_SAMPLE_X256 / 256
	; BC = DE (consumed), DE -> tick, HL = 1024 - tick
	LD	B,D
	LD	C,E			; BC = DE (for save)
	; 16x16 multiply DE * 322 -> HL:DEhi (we only need /256)
	CALL	MUL_DE_322		; HL = (DE * 322) >> 8 (clipped to 16bit)
	; NA = 1024 - HL
	PUSH	HL
	LD	HL,1024
	POP	DE
	OR	A
	SBC	HL,DE
	; if NA < 1 (HL <= 0), clamp to 1 (safety; should not happen since DE<=511 -> tick<=643)
	LD	A,H
	OR	A
	JR	NZ,.OK
	LD	A,L
	OR	A
	JR	NZ,.OK
	LD	HL,1
.OK:
	; DE -= BC (consumed) ; here DE was the multiplied result, restore via 0
	LD	DE,0			; DE was modified by multiply; remaining = 0
	RET

;-------------------------------------------------
; MUL_DE_322 - HL = (DE * 322) >> 8, clipped to 16bit
; trash: A, DE (preserved input copied into HL via mul)
;-------------------------------------------------
; 322 = 0x142 = 256 + 64 + 2
; DE * 322 = DE*256 + DE*64 + DE*2
; >> 8 -> DE + (DE*64)>>8 + (DE*2)>>8 = DE + (DE>>2) + (DE>>7)
; For DE <= 511: DE*322 <= 164,542 (17bit). >>8 <= 642 (10bit) -> safe in HL.
MUL_DE_322:
	; HL = DE
	LD	H,D
	LD	L,E
	; HL += DE >> 2
	PUSH	DE
	SRL	D
	RR	E
	SRL	D
	RR	E
	ADD	HL,DE
	POP	DE
	; HL += DE >> 7
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
; TA_LOAD_HL - write Timer A 10-bit preload to 24H/25H
;  IN HL = preload value (0..1023)
;  Timer A high = HL >> 2 (8bit), Timer A low = HL & 3 (low 2bit)
;-------------------------------------------------
TA_LOAD_HL:
	PUSH	HL
	PUSH	AF
	; high byte = HL >> 2
	SRL	H
	RR	L
	SRL	H
	RR	L
	LD	A,TA_REG_HI
	OUT	(OPN_ADDR),A
	NOP
	LD	A,L
	OUT	(OPN_DATA),A
	POP	AF
	POP	HL
	PUSH	HL
	PUSH	AF
	; low 2 bits
	LD	A,L
	AND	03H
	LD	B,A
	LD	A,TA_REG_LO
	OUT	(OPN_ADDR),A
	NOP
	LD	A,B
	OUT	(OPN_DATA),A
	POP	AF
	POP	HL
	RET

;-------------------------------------------------
; TA_START - 27H <- TA_CTRL_RUN_IRQEN (LoadA=1, IRQEN A=1)
;-------------------------------------------------
TA_START:
	LD	A,TA_REG_CTRL
	OUT	(OPN_ADDR),A
	NOP
	LD	A,TA_CTRL_RUN_IRQEN
	LD	(TA_CTRL_SHADOW),A
	OUT	(OPN_DATA),A
	RET

;-------------------------------------------------
; TA_STOP - stop Timer A and reset its flag
;-------------------------------------------------
TA_STOP:
	LD	A,TA_REG_CTRL
	OUT	(OPN_ADDR),A
	NOP
	LD	A,TA_CTRL_STOP_RESET
	LD	(TA_CTRL_SHADOW),A
	OUT	(OPN_DATA),A
	; second write to clear reset bit
	LD	A,TA_REG_CTRL
	OUT	(OPN_ADDR),A
	NOP
	LD	A,0
	LD	(TA_CTRL_SHADOW),A
	OUT	(OPN_DATA),A
	RET

;-------------------------------------------------
; IRQ_SETUP - save vector entry, install ISR, init Timer A, EI
;-------------------------------------------------
IRQ_SETUP:
	DI
	; HL = $8000 + IVR_FMTAV
	LD	A,(IVR_FMTAV)
	LD	L,A
	LD	H,IVT_PAGE
	LD	(IVT_PTR),HL
	; save existing entry
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	LD	(SAVED_VEC_FMTA),DE
	; install our handler
	LD	HL,(IVT_PTR)
	LD	DE,ISR_FMTA
	LD	(HL),E
	INC	HL
	LD	(HL),D
	; force I=80H, IM 2
	LD	A,IVT_PAGE
	LD	I,A
	IM	2
	; initialise Timer A: stop+reset, then start with first preload set later
	CALL	TA_STOP
	; small initial preload (about 1ms) so first HALT exits quickly even if main forgets
	LD	HL,944			; 1024 - (~80 ticks) ~= 1.44ms @ 18us/tick
	CALL	TA_LOAD_HL
	EI
	RET

;-------------------------------------------------
; IRQ_TEARDOWN - stop timer, restore vector, IM 1, EI
;-------------------------------------------------
IRQ_TEARDOWN:
	DI
	CALL	TA_STOP
	; restore vector
	LD	HL,(IVT_PTR)
	LD	DE,(SAVED_VEC_FMTA)
	LD	(HL),E
	INC	HL
	LD	(HL),D
	IM	1
	EI
	RET

;-------------------------------------------------
; ISR_FMTA - minimal ISR. Reset Timer A flag, set TA_TICK, EI+RETI.
;-------------------------------------------------
ISR_FMTA:
	EX	AF,AF'
	PUSH	BC
	; pulse-reset Timer A overflow flag
	LD	A,TA_REG_CTRL
	OUT	(OPN_ADDR),A
	LD	A,(TA_CTRL_SHADOW)
	LD	B,A
	OR	TA_FLAG_RESET_A_MASK
	OUT	(OPN_DATA),A
	; restore control byte (clear reset pulse)
	LD	A,TA_REG_CTRL
	OUT	(OPN_ADDR),A
	LD	A,B
	OUT	(OPN_DATA),A
	; set tick flag
	LD	A,1
	LD	(TA_TICK),A
	POP	BC
	EX	AF,AF'
	EI
	RETI

;-------------------------------------------------
; RB_FILL_OPPORTUNISTIC - refill ring buffer before HALT
;  IN BC = samples in this chunk (unused for now, kept for future tuning)
;-------------------------------------------------
RB_FILL_OPPORTUNISTIC:
	; if buffer is near full (CNT >= HIWATER), skip
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
; Ring buffer primitives (lifted from VGMPLAY.asm)
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
; PLAY_FILE - open, parse hdr, prefill, install IRQ, run PLAY
;=================================================
PLAY_FILE:
	LD	HL,PLAYNAME
	CALL	STRM_OPEN
	JR	C,.nf
	LD	(PLAYSP),SP
	CALL	RB_INIT
	CALL	PARSE_HDR
	CALL	RB_PREFILL
	CALL	IRQ_SETUP
	JP	PLAY
.nf:	LD	HL,MSG_NF
	CALL	PUTS
	RET

;=================================================
; Directory listing (lifted from VGMPLAY.asm)
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

;=================================================
; READ_NUM - decimal number + Enter
;=================================================
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

;=================================================
; PRDEC - print A (0..255) in decimal, leading-zero suppressed
;=================================================
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
MSG_HDR:	DB	CR,LF,"-- VGM (IRQ) --",CR,LF,00H
MSG_COLON:	DB	": ",00H
MSG_PROMPT:	DB	CR,LF,"NO(0=END)? ",00H
VGMEXT:		DB	"VGM"
MSG_NF:		DB	CR,LF,"NOT FOUND",CR,LF,00H
MSG_NOTVGM:	DB	CR,LF,"NOT VGM",CR,LF,00H
MSG_BADHDR:	DB	CR,LF,"BAD HEADER",CR,LF,00H
MSG_BADCMD:	DB	CR,LF,"BAD COMMAND",CR,LF,00H
MSG_END:	DB	CR,LF,"VGM END",CR,LF,00H
MSG_BRK:	DB	CR,LF,"BREAK",CR,LF,00H

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

; --- IRQ-related ---
IVT_PTR:	DS	2		; cached $8000 + IVR_FMTAV
SAVED_VEC_FMTA:	DS	2		; original vector entry (2 bytes)
TA_TICK:	DS	1		; ISR sets this to 1
TA_CTRL_SHADOW:	DS	1		; current 27H control byte

STACK:		DS	256
STACK_TOP	EQU	$

	END
