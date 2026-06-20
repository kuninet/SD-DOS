
;PIC版SDドライバ(PC8001extSDRTC ボード用)
;・SDアクセスを、PC-8001外部バスに直結したPIC18F47Q43のI/Oデバイスに肩代わりさせる。
;  8255ビットバンギング(MMC.asm)の代替。エントリ名は MMC.asm と同一に保ち、
;  FS.asm / STRM.asm など上位は無変更で差し替えられるようにする。
;・I/Oプロトコル(D0H-D6H)の詳細は PC8001extSDRTC リポジトリの docs/protocol.md を参照。
;・本ファイルは USE_PICSD=TRUE のときだけ INCLUDE される(MAIN.asm)。

;=================================================
;[MMC_PIC]I/Oポート定義
;=================================================
PICSD_CMD	EQU	0D0H		;W  コマンドレジスタ
PICSD_ADR0	EQU	0D1H		;W  セクタアドレス byte0(LSB)
PICSD_ADR1	EQU	0D2H		;W  セクタアドレス byte1
PICSD_ADR2	EQU	0D3H		;W  セクタアドレス byte2
PICSD_ADR3	EQU	0D4H		;W  セクタアドレス byte3(MSB)
PICSD_DATA	EQU	0D5H		;R/W 512Bセクタバッファ ストリーム入出力
PICSD_STAT	EQU	0D6H		;R  ステータスレジスタ

;コマンド(PICSD_CMD へ書く)
CMD_READ	EQU	00H		;セクタREAD(ADRのセクタをPICバッファへ)
CMD_WRITE	EQU	01H		;セクタWRITE(PICバッファをADRへ書き戻す)
CMD_STATUS	EQU	02H		;ステータス更新
CMD_INIT	EQU	03H		;SD初期化/マウント

;ステータスビット(PICSD_STAT を読む)
ST_READY	EQU	00000001B	;bit0 操作完了・データ転送可
ST_BUSY		EQU	00000010B	;bit1 SDアクセス中
ST_ERROR	EQU	10000000B	;bit7 エラー

VLED_POS:	EQU	VRAM+78			;仮想LEDの位置

;=================================================
;[MMC_PIC]8255モードセット(PIC版: 8255は無いのでスタブ)
;・SDの存在確認/初期化は MMC_INIT(=PICへ CMD_INIT)で行う。
;  上位(CMD.asm)が INIT_8255 を呼ぶため、シンボル互換のため残す。
;=================================================
INIT_8255:
	RET

;=================================================
;[MMC_PIC]PICへセクタアドレス(MMCADR0-3)を渡す
;IN  MMCADR0,1,2,3
;OUT -  (A破壊)
;=================================================
MMCP_SETADR:
	LD	A,(MMCADR0)
	OUT	(PICSD_ADR0),A
	LD	A,(MMCADR1)
	OUT	(PICSD_ADR1),A
	LD	A,(MMCADR2)
	OUT	(PICSD_ADR2),A
	LD	A,(MMCADR3)
	OUT	(PICSD_ADR3),A
	RET

;=================================================
;[MMC_PIC]READYになるまでステータスをpollingする
;・SDアクセス中はZ80を/WAITで固めず、ここでpollingして待つ。
;・タイムアウトしたら MMC_TIMEOUT へ(SD未装着扱い)。
;IN  -
;OUT -  (A破壊)
;=================================================
MMCP_WAITRDY:
	PUSH	BC
	LD	BC,0				;65536回まで待つ
.LOOP:	IN	A,(PICSD_STAT)
	AND	ST_READY
	JR	NZ,.DONE
	DEC	BC
	LD	A,B
	OR	C
	JR	NZ,.LOOP
	POP	BC
	JP	MMC_TIMEOUT			;タイムアウト
.DONE:	POP	BC
	RET

;=================================================
;[MMC_PIC]MMCをSPIモードに初期化する(=PICにSDをマウントさせる)
;IN  -
;OUT -
;=================================================
MMC_INIT:
	LD	A,CMD_INIT
	OUT	(PICSD_CMD),A
	CALL	MMCP_WAITRDY
	IN	A,(PICSD_STAT)
	AND	ST_ERROR
	JP	NZ,MMC_TIMEOUT			;初期化失敗=カード無し扱い
	RET

;=================================================
;[MMC_PIC]タイムアウト処理(MMC.asm と同一メッセージ)
;=================================================
MMC_TIMEOUT:
	CALL	IPRINT
	DB	"Set SDC then ",DQUOTE,"MOUNT",DQUOTE,CR,LF,EOL
	LD	E,UNPRINTABLE
	JP	ERROR

;=================================================
;[MMC_PIC]MMCから1バイト受け取る
;IN  -
;OUT C=受信データ  (A破壊)
;=================================================
MMC_1RD:
	IN	A,(PICSD_DATA)
	LD	C,A
	RET

;=================================================
;[MMC_PIC]MMCに1バイト送る
;IN  C=送信データ
;OUT -  (A破壊)
;=================================================
MMC_1WR:
	LD	A,C
	OUT	(PICSD_DATA),A
	RET

;=================================================
;[MMC_PIC]ブロックREADコマンド
;・PICにセクタを読ませ、512Bバッファ先頭にロードさせる。
;  以後 MMC_1RD で先頭から1バイトずつ取り出せる。
;IN  MMCADR0-3=セクタアドレス
;OUT -
;=================================================
MMC_BRD_CMD:
	CALL	MMCP_SETADR
	LD	A,CMD_READ
	OUT	(PICSD_CMD),A
	CALL	MMCP_WAITRDY
	RET

;=================================================
;[MMC_PIC]ブロックREAD終了処理
;・ビットバンギング版はCRC2バイトを読み捨てるが、PIC側でCRC処理済みのため不要。
;=================================================
MMC_BRD_END:
	RET

;=================================================
;[MMC_PIC]物理アドレスクリア
;=================================================
MMC_CLR_ADR:
	XOR	A
	LD	(MMCADR0),A
	LD	(MMCADR1),A
	LD	(MMCADR2),A
	LD	(MMCADR3),A
	RET

;=================================================
;[MMC_PIC]物理アドレスを1ブロック分(512バイト)進める
;・ビットバンギング版と同一(MMCADR=バイトアドレス、+200H)。
;=================================================
MMC_INC_ADR:
	LD	A,(MMCADR1)
	ADD	A,2
	LD	(MMCADR1),A
	LD	A,(MMCADR2)
	ADC	A,0
	LD	(MMCADR2),A
	LD	A,(MMCADR3)
	ADC	A,0
	LD	(MMCADR3),A
	RET

;=================================================
;[MMC_PIC]MMC読み込み
;IN  MMCADR0,1,2,3=MMCアドレス HL=メモリアドレス B=ブロック数
;OUT -
;=================================================
MMC_READ:
	PUSH	BC

	CALL	MMC_LED_ON

	CALL	MMC_BRD_CMD
	LD	B,2
.L1:	PUSH	BC
	LD	B,0				;256回ループ
.L2:	PUSH	BC
	CALL	MMC_1RD
	LD	(HL),C
	INC	HL
	POP	BC
	DJNZ	.L2
	POP	BC
	DJNZ	.L1
	CALL	MMC_BRD_END
	CALL	MMC_INC_ADR
	POP	BC

	CALL	MMC_LED_OFF

	DJNZ	MMC_READ
	RET

;=================================================
;[MMC_PIC]MMC書き込み
;IN  MMCADR0,1,2,3=MMCアドレス HL=メモリアドレス B=ブロック数
;OUT -
;=================================================
MMC_WRITE:
	PUSH	BC

	CALL	MMC_LED_ON

	CALL	MMCP_SETADR
	LD	A,CMD_WRITE
	OUT	(PICSD_CMD),A
	LD	B,2
.L1:	PUSH	BC
	LD	B,0
.L2:	PUSH	BC
	LD	C,(HL)
	INC	HL
	CALL	MMC_1WR
	POP	BC
	DJNZ	.L2
	POP	BC
	DJNZ	.L1
	CALL	MMCP_WAITRDY			;フラッシュ完了待ち
	CALL	MMC_INC_ADR
	POP	BC

	CALL	MMC_LED_OFF

	DJNZ	MMC_WRITE
	RET

;=================================================
;アクセスランプ点灯(PIC版: 8255 PPI を叩かず仮想LED/音のみ)
;=================================================
MMC_LED_ON:
IF USE_VIRTUAL_SOUND
	LD	A,(SD_SND_OFF)		;ストリーム読み出し中は疑似音を鳴らさない
	OR	A
	CALL	Z,MMC_SOUND
ENDIF

	LD	A,(INFO_SW)			;インフォメーションフラグが降りていたら戻る
	AND	A
	RET	Z

IF USE_VIRTUAL_LED
	LD	A,02AH				;="*"
	LD	(VLED_POS),A
ENDIF

	RET

;=================================================
;アクセスランプ消灯(PIC版)
;=================================================
MMC_LED_OFF:
	LD	A,(INFO_SW)
	AND	A
	RET	Z

IF USE_VIRTUAL_LED
	XOR	A				;=NULL文字
	LD	(VLED_POS),A
ENDIF
	RET

;=================================================
;疑似アクセス音
;=================================================
IF USE_VIRTUAL_SOUND
MMC_SOUND:
	PUSH	BC

	LD	B,20H
.L1:	LD	A,(0EA67H)
	OR	00100000B
	OUT	(40H),A
	AND	11011111B
	OUT	(40H),A
	DJNZ	.L1

	POP	BC
	RET
ENDIF

