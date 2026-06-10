;=================================================
;SDUMP - ストリーム読み出しAPI 検証用サンプル
;=================================================
;・FNAMEで指定したファイルを開き、先頭128バイトを16進ダンプした後、
;  終端まで読み続けて読んだバイト数(16進4桁)を表示する
;・使い方
;    LOAD "SDUMP.CMT"
;    CMD R
;・対象のファイル名はFNAME(本ソース末尾)を書き換えてアセンブルする
;・読んだバイト数の表示は下位16ビットのみ(64KB超のファイルでは折り返す)
;・APIの仕様は docs/design/api-spec.md を参照
;=================================================

STRM_OPEN	EQU	6005H		;ストリームを開く
STRM_READ	EQU	6008H		;１バイト取得
STRM_CLOSE	EQU	600BH		;ストリームを閉じる
CR		EQU	0DH		;

	ORG	09000H

START:
	LD	HL,FNAME		;ファイルを開く
	CALL	STRM_OPEN		;
	JR	NC,.OK			;
	LD	HL,MSG_NF		;見つからなければメッセージを表示して終了
	JR	PUTS			;

.OK:	LD	DE,0000H		;DE=読んだバイト数
	LD	B,128			;B=ダンプするバイト数
.DUMP:	CALL	STRM_READ		;１バイト取得
	JR	C,.EOF			;CY=1:EOF
	INC	DE			;
	CALL	PRT_HEX2		;16進2桁で表示
	LD	A," "			;
	RST	18H			;
	LD	A,E			;8バイトごとに改行
	AND	07H			;
	CALL	Z,PUT_CR		;
	DJNZ	.DUMP			;

.REST:	CALL	STRM_READ		;残りは表示せずにEOFまで読む
	JR	C,.EOF			;
	INC	DE			;
	JR	.REST			;

.EOF:	CALL	STRM_CLOSE		;ストリームを閉じる
	LD	HL,MSG_LEN		;読んだバイト数を表示する
	CALL	PUTS			;
	LD	A,D			;
	CALL	PRT_HEX2		;
	LD	A,E			;
	CALL	PRT_HEX2		;
	LD	A,"H"			;
	RST	18H			;
	JR	PUT_CR			;表示して終了

;-------------------------------------------------
;00H終端文字列の表示
;IN  HL=文字列の先頭アドレス
;-------------------------------------------------
PUTS:	LD	A,(HL)			;
	OR	A			;
	RET	Z			;
	RST	18H			;
	INC	HL			;
	JR	PUTS			;

;-------------------------------------------------
;改行の表示
;-------------------------------------------------
PUT_CR:	LD	A,CR			;
	RST	18H			;
	RET				;

;-------------------------------------------------
;Aレジスタの値を16進2桁で表示する
;IN  A=値
;-------------------------------------------------
PRT_HEX2:
	PUSH	AF			;上位4ビット
	RRCA				;
	RRCA				;
	RRCA				;
	RRCA				;
	CALL	.NIB			;
	POP	AF			;下位4ビットへ続く
.NIB:	AND	0FH			;
	ADD	A,"0"			;
	CP	"9"+1			;
	JR	C,.PUT			;A-Fなら補正
	ADD	A,07H			;
.PUT:	RST	18H			;
	RET				;

FNAME:	DB	"/SAMPLE.DAT",00H	;対象のファイル名(00H終端)
MSG_NF:	DB	CR,"NOT FOUND",CR,00H	;
MSG_LEN:DB	CR,"READ:",00H		;

	END
