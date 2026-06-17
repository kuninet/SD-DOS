;=================================================
;PC-8001 SD-DOS 64KB RAM版ローダ
;=================================================
;・64KRAM.hex(EPROM 6000H-7FFFH用)の先頭に置くローダ
;・転送ルーチンを高位RAM(0D000H)へコピーしてから実行する
;・BASIC ROM(0000H-5FFFH)とSD-DOS本体を裏RAMへコピーし、
;  バンクを切り替えたうえで6000Hから起動する
;・SD-DOS本体(MAIN.asmの出力)はBODY(604CH)以降に合成して配置する
;  合成手順は scripts/make64kram.py と docs/build.md を参照

RELOC	EQU	0D000H			;転送ルーチンの実行アドレス
BANK	EQU	0E2H			;拡張RAMバンク制御ポート

	ORG	06000H

	DB	"AB"			;自動起動用マーカー
	LD	HL,STUB			;転送ルーチンをRELOCへコピーする
	LD	DE,RELOC		;
	LD	BC,STUB_END-STUB	;
	LDIR				;
	JP	RELOC			;

;-------------------------------------------------
;転送ルーチン(RELOCへコピーされて実行される)
;・内部に絶対参照を持たないため、配置先でもそのまま動く
;-------------------------------------------------
STUB:
	LD	A,88H			;ハードウェア初期化
	OUT	(0FFH),A		;
	LD	A,0F7H			;ポートFDHの応答を確認する
	OUT	(0FDH),A		;
	IN	A,(0FDH)		;
	CP	0F7H			;応答がなければBASICへ戻る
	RET	NZ			;
	LD	A,0FFH			;
	OUT	(0FDH),A		;
	LD	A,10H			;裏RAMへの書き込みを有効にする
	OUT	(BANK),A		;
	LD	HL,0000H		;BASIC ROM(0000H-5FFFH)を裏RAMへコピー
	LD	DE,0000H		;
	LD	BC,6000H		;
	LDIR				;
	LD	HL,BODY			;SD-DOS本体を6000Hへコピー
	LD	DE,6000H		;
	LD	BC,BODY_LEN		;
	LDIR				;
	LD	A,11H			;裏RAMの読み出しへ切り替える
	OUT	(BANK),A		;
	LD	HL,6000H		;RAMへ切り替わったことを確認する
	LD	E,(HL)			;
	LD	A,00H			;
	LD	(HL),A			;
	CP	(HL)			;書き込めなければBASICへ戻る
	RET	NZ			;
	LD	(HL),E			;
	JP	6000H			;SD-DOSを起動する
STUB_END:

BODY:					;ここ(604CH)以降にMAIN.asmの出力を合成する
BODY_LEN	EQU	1C00H		;ローダがコピーする本体の長さ ！本体がこの長さを超えたら更新すること！

	END
