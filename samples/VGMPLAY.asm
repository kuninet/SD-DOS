;=================================================
;VGMPLAY - VGM再生サンプル（YM2203/PSG両対応）
;=================================================
;・FNAMEで指定したVGMファイル（無圧縮）をストリーム読み出しAPIで
;  読みながら、YM2203ボード（80H/81H）とPSGボード（0A0H/0A1H）へ出力する
;・両ボードのコマンドを1本で処理する。未接続ポートへのOUTは無害
;・使い方
;    LOAD "VGMPLAY.CMT"
;    CMD R
;・対象のファイル名はFNAME（本ソース末尾）を書き換えてアセンブルする
;・ヘッダ解析範囲は docs/vgm/header.md、コマンドと読み飛ばし規則は
;  docs/vgm/commands.md、音源の書き込み手順は docs/vgm/sound-io.md を参照
;・タイミングはビジーループ近似。テンポは WAIT_K(既定値)で決まる
;・実機調整: LOAD後 POKE &H9003,n (n=1～255 小さいほど速い)してから CMD R で再生
;  9003H は WAIT_KV(ウェイト係数)の固定アドレス
;=================================================

STRM_OPEN	EQU	6005H		;ストリームを開く
STRM_READ	EQU	6008H		;１バイト取得
STRM_CLOSE	EQU	600BH		;ストリームを閉じる
OPN_ADDR	EQU	80H		;YM2203 レジスタ番号/ステータス
OPN_DATA	EQU	81H		;YM2203 データ
PSG_ADDR	EQU	0A0H		;PSG#1 レジスタ番号
PSG_DATA	EQU	0A1H		;PSG#1 データ
WAIT_K	EQU	5		;1サンプル（約22.7マイクロ秒）の内側ループ回数 ！実機で調整！
CR	EQU	0DH		;
RBUF_SIZE	EQU	1000H		;先読みリングバッファのサイズ（4KB。貯金枠）

	ORG	09000H

	JP	START			;9000H 実行エントリ(CMD Rでここへ来る)
WAIT_KV:	DB	WAIT_K		;9003H ウェイト係数。POKE &H9003,n で実機調整可能
	DB	0,0			;9004H,9005H 予備

START:
	LD	(SAVSP),SP		;異常終了時の脱出用にSPを保存する
	LD	HL,FNAME		;ファイルを開く
	CALL	STRM_OPEN		;
	JR	NC,.OK			;
	LD	HL,MSG_NF		;見つからなければメッセージを表示して終了
	JP	PUTS			;

.OK:	CALL	RB_INIT			;リングバッファ初期化
	CALL	PARSE_HDR		;ヘッダを解析してデータ開始位置まで進める
	CALL	RB_REFILL		;再生開始前にバッファをプライム
	JP	PLAY			;再生ループへ

;-------------------------------------------------
;正常終了（再生終了・EOF）
;-------------------------------------------------
DONE:
	LD	SP,(SAVSP)		;
	CALL	STRM_CLOSE		;
	LD	HL,MSG_END		;
	JP	PUTS			;

;-------------------------------------------------
;異常終了
;IN  HL=メッセージ
;-------------------------------------------------
ABORT:
	LD	SP,(SAVSP)		;
	PUSH	HL			;
	CALL	STRM_CLOSE		;
	POP	HL			;
	JP	PUTS			;

;-------------------------------------------------
;ヘッダ解析（docs/vgm/header.md の最小解析範囲）
;・識別子を確認し、バージョンからデータ開始位置を求めて読み進める
;-------------------------------------------------
PARSE_HDR:
	LD	HL,IDENT		;識別子 "Vgm " の確認
	LD	B,4			;
.ID:	CALL	GETB			;
	CP	(HL)			;
	JR	NZ,.NOTVGM		;
	INC	HL			;
	DJNZ	.ID			;
	LD	DE,4			;04H-07H（EOFオフセット）を読み捨てる
	CALL	SKIP			;
	CALL	GETB			;08H- バージョン（BCD）下位ワード
	LD	C,A			;
	CALL	GETB			;
	LD	B,A			;BC=バージョン下位ワード
	CALL	GETB			;上位2バイトは読み捨てる
	CALL	GETB			;
	LD	H,B			;バージョン1.50未満なら旧形式
	LD	L,C			;
	LD	DE,0150H		;
	OR	A			;
	SBC	HL,DE			;
	JR	C,.OLD			;
	LD	DE,0028H		;0CH-33Hを読み捨てる
	CALL	SKIP			;
	CALL	GETB			;34H- データ開始オフセット（34Hからの相対）
	LD	E,A			;
	CALL	GETB			;
	LD	D,A			;DE=オフセット下位ワード
	CALL	GETB			;上位2バイトが0以外なら異常
	LD	C,A			;
	CALL	GETB			;
	OR	C			;
	JR	NZ,.BADHDR		;
	EX	DE,HL			;残り読み捨て数=オフセット-4（38Hまで読み済み）
	LD	DE,4			;
	OR	A			;
	SBC	HL,DE			;
	JR	C,.BADHDR		;オフセットが4未満なら異常
	EX	DE,HL			;
	JP	SKIP			;データ開始位置まで読み捨てて戻る

.OLD:	LD	DE,0034H		;旧形式はデータ開始40H固定。0CH-3FHを読み捨てる
	JP	SKIP			;

.NOTVGM:
	LD	HL,MSG_NOTVGM		;
	JP	ABORT			;
.BADHDR:
	LD	HL,MSG_BADHDR		;
	JP	ABORT			;

;-------------------------------------------------
;再生ループ（docs/vgm/commands.md のコマンド表）
;-------------------------------------------------
PLAY:
.LOOP:	CALL	GETB			;コマンド取得
	CP	66H			;終了コマンド
	JP	Z,DONE			;
	CP	55H			;YM2203書き込み
	JR	Z,.OPN			;
	CP	0A0H			;PSG書き込み
	JR	Z,.PSG			;
	CP	61H			;ウェイト（サンプル数指定）
	JR	Z,.W61			;
	CP	62H			;ウェイト（735サンプル）
	JR	Z,.W62			;
	CP	63H			;ウェイト（882サンプル）
	JR	Z,.W63			;
	LD	C,A			;C<-コマンド退避
	AND	0F0H			;
	CP	70H			;70H-7FH:短いウェイト
	JR	Z,.W7X			;
	CP	80H			;80H-8FH:YM2612 DAC+ウェイト
	JR	Z,.LOOP			;対象チップがないため無視する
	LD	A,C			;
	JP	SKIP_CMD		;その他は読み飛ばし規則へ

.OPN:	CALL	GETB			;C<-レジスタ番号
	LD	C,A			;
	CALL	GETB			;B<-データ値
	LD	B,A			;
.BUSY:	IN	A,(OPN_ADDR)		;BUSY（ビット7）が下りるまで待つ
	RLCA				;
	JR	C,.BUSY			;
	LD	A,C			;レジスタ番号を出力
	OUT	(OPN_ADDR),A		;
	LD	A,(FNAME)		;レジスタ選択後の短い待ち（ダミー読み）
	LD	A,B			;データ値を出力
	OUT	(OPN_DATA),A		;
	JR	.LOOP			;

.PSG:	CALL	GETB			;レジスタ番号を出力
	OUT	(PSG_ADDR),A		;
	CALL	GETB			;データ値を出力
	OUT	(PSG_DATA),A		;
	JR	.LOOP			;

.W61:	CALL	GETB			;DE<-サンプル数
	LD	E,A			;
	CALL	GETB			;
	LD	D,A			;
	CALL	WAIT_DE			;
	JR	.LOOP			;
.W62:	LD	DE,735			;1/60秒
	CALL	WAIT_DE			;
	JR	.LOOP			;
.W63:	LD	DE,882			;1/50秒
	CALL	WAIT_DE			;
	JR	.LOOP			;
.W7X:	LD	A,C			;（下位4ビット+1）サンプル
	AND	0FH			;
	INC	A			;
	LD	E,A			;
	LD	D,0			;
	CALL	WAIT_DE			;
	JR	.LOOP			;

;-------------------------------------------------
;未対応コマンドの読み飛ばし（docs/vgm/commands.md の規則）
;IN  A=コマンド
;-------------------------------------------------
SKIP_CMD:
	CP	30H			;00H-2FH:未知
	JR	C,.BAD			;
	CP	40H			;30H-3FH:1バイト
	JR	C,.S1			;
	CP	4FH			;40H-4EH:未知
	JR	C,.BAD			;
	CP	51H			;4FH,50H:1バイト
	JR	C,.S1			;
	CP	60H			;51H-5FH:2バイト
	JR	C,.S2			;
	CP	64H			;64H:3バイト
	JR	Z,.S3			;
	CP	67H			;67H:データブロック
	JR	Z,.BLK			;
	CP	90H			;60H,65H,68H-6FH:未知
	JR	C,.BAD			;
	CP	96H			;90H-95H:DACストリーム
	JR	C,.S9X			;
	CP	0A1H			;96H-0A0H:未知
	JR	C,.BAD			;
	CP	0C0H			;0A1H-0BFH:2バイト
	JR	C,.S2			;
	CP	0E0H			;0C0H-0DFH:3バイト
	JR	C,.S3			;
.S4:	CALL	GETB			;0E0H-0FFH:4バイト
.S3:	CALL	GETB			;
.S2:	CALL	GETB			;
.S1:	CALL	GETB			;
	JP	PLAY.LOOP		;

.BAD:	LD	HL,MSG_BADCMD		;未知のコマンドは解釈が崩れているため停止
	JP	ABORT			;

.S9X:	SUB	90H			;90H-95Hのオペランド長を表から引く
	LD	HL,TBL9X		;
	LD	E,A			;
	LD	D,0			;
	ADD	HL,DE			;
	LD	B,(HL)			;
.S9L:	CALL	GETB			;
	DJNZ	.S9L			;
	JP	PLAY.LOOP		;

.BLK:	CALL	GETB			;66H（互換用バイト）
	CALL	GETB			;ブロックタイプ
	LD	HL,BLKSZ		;サイズ4バイト（リトルエンディアン）
	LD	B,4			;
.BSZ:	CALL	GETB			;
	LD	(HL),A			;
	INC	HL			;
	DJNZ	.BSZ			;
.BSKIP:	LD	HL,BLKSZ		;サイズが0になるまで読み捨てる
	LD	B,4			;
	XOR	A			;
.BZ:	OR	(HL)			;
	INC	HL			;
	DJNZ	.BZ			;
	OR	A			;
	JP	Z,PLAY.LOOP		;
	LD	HL,BLKSZ		;サイズを1減らす（4バイトの桁借り伝播）
	LD	A,(HL)			;
	SUB	1			;
	LD	(HL),A			;
	JR	NC,.BRD			;
	LD	B,3			;
.BD:	INC	HL			;
	LD	A,(HL)			;
	SBC	A,0			;
	LD	(HL),A			;
	JR	NC,.BRD			;
	DJNZ	.BD			;
.BRD:	CALL	GETB			;
	JR	.BSKIP			;

;-------------------------------------------------
;指定バイト数の読み捨て
;IN  DE=バイト数
;-------------------------------------------------
SKIP:	LD	A,D			;
	OR	E			;
	RET	Z			;
	CALL	GETB			;
	DEC	DE			;
	JR	SKIP			;

;-------------------------------------------------
;１バイト取得（EOFは再生終了として扱う）
;OUT A=取得した値
;-------------------------------------------------
GETB:	PUSH	HL			;HL/DE/BCを保存（呼び出し側がHL等を使う）
	PUSH	DE			;
	PUSH	BC			;
	CALL	RB_GET			;リングバッファから取得
	JR	NC,.GOT			;取得できた
	LD	A,(RB_EOF)		;バッファ空。先読みが終端に達していれば
	OR	A			;
	JR	NZ,.EOF			;再生終了へ
	CALL	STRM_READ		;フォールバック：直接読み（空かつ未終端）
	JR	C,.RDEOF		;
.GOT:	POP	BC			;
	POP	DE			;
	POP	HL			;
	RET				;A=取得した値
.RDEOF:	LD	A,0FFH			;直接読みでEOF
	LD	(RB_EOF),A		;
.EOF:	POP	BC			;
	POP	DE			;
	POP	HL			;
	JP	DONE			;EOFは再生終了として扱う

;-------------------------------------------------
;サンプル数ぶんのウェイト
;IN  DE=サンプル数
;-------------------------------------------------
WAIT_DE:
	CALL	RB_REFILL		;ウェイトの空き時間に先読みする
	LD	A,D			;
	OR	E			;
	RET	Z			;
.L:	LD	A,(WAIT_KV)		;ウェイト係数(実機POKEで可変)
	LD	B,A			;
.W:	DJNZ	.W			;
	DEC	DE			;
	LD	A,D			;
	OR	E			;
	JR	NZ,.L			;
	RET				;


;-------------------------------------------------
;先読みリングバッファ（SD読み込み遅延をウェイト中に隠す）
;-------------------------------------------------
;[RB]初期化
RB_INIT:
	LD	HL,RBUF			;
	LD	(RB_RDP),HL		;読み書きポインタを先頭へ
	LD	(RB_WRP),HL		;
	LD	HL,0			;
	LD	(RB_CNT),HL		;バイト数=0
	XOR	A			;
	LD	(RB_EOF),A		;終端フラグ=0
	RET				;

;[RB]1バイト格納（満タンでないこと） IN A=値
RB_PUT:
	PUSH	HL			;
	PUSH	DE			;
	LD	HL,(RB_WRP)		;
	LD	(HL),A			;格納
	INC	HL			;
	LD	DE,RBUF_END		;末尾なら先頭へラップ
	LD	A,H			;
	CP	D			;
	JR	NZ,.NW			;
	LD	A,L			;
	CP	E			;
	JR	NZ,.NW			;
	LD	HL,RBUF			;
.NW:	LD	(RB_WRP),HL		;
	LD	HL,(RB_CNT)		;バイト数++
	INC	HL			;
	LD	(RB_CNT),HL		;
	POP	DE			;
	POP	HL			;
	RET				;

;[RB]1バイト取得 OUT A=値,CY=0 / CY=1:空
;！BC/DE/HLを壊す（呼び出し側GETBが保存している）
RB_GET:
	LD	HL,(RB_CNT)		;
	LD	A,H			;
	OR	L			;
	SCF				;空ならCY=1
	RET	Z			;
	LD	HL,(RB_RDP)		;
	LD	B,(HL)			;値→B
	INC	HL			;
	LD	DE,RBUF_END		;末尾なら先頭へラップ
	LD	A,H			;
	CP	D			;
	JR	NZ,.NW			;
	LD	A,L			;
	CP	E			;
	JR	NZ,.NW			;
	LD	HL,RBUF			;
.NW:	LD	(RB_RDP),HL		;
	LD	HL,(RB_CNT)		;バイト数--
	DEC	HL			;
	LD	(RB_CNT),HL		;
	LD	A,B			;値→A
	OR	A			;CY=0
	RET				;

;[RB]空き時間にバッファを満タンまで先読みする
RB_REFILL:
	LD	A,(RB_EOF)		;既に終端なら何もしない
	OR	A			;
	RET	NZ			;
	PUSH	BC			;
	PUSH	DE			;DEはWAIT_DEのサンプル数。保存必須
	PUSH	HL			;
.R:	LD	HL,(RB_CNT)		;CNT>=RBUF_SIZE なら満タン
	LD	DE,RBUF_SIZE		;
	OR	A			;CY=0
	SBC	HL,DE			;
	JR	NC,.FULL		;
	CALL	STRM_READ		;1バイト先読み
	JR	C,.EOF			;CY=1:終端
	CALL	RB_PUT			;バッファへ
	JR	.R			;
.EOF:	LD	A,0FFH			;終端フラグを立てる
	LD	(RB_EOF),A		;
.FULL:	POP	HL			;
	POP	DE			;
	POP	BC			;
	RET				;

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

IDENT:	DB	"Vgm "			;VGM識別子
TBL9X:	DB	4,4,5,10,1,4		;90H-95Hのオペランド長
FNAME:	DB	"/MUSIC.VGM",00H	;対象のファイル名（00H終端）
MSG_NF:	DB	CR,"NOT FOUND",CR,00H	;
MSG_NOTVGM:
	DB	CR,"NOT VGM",CR,00H	;
MSG_BADHDR:
	DB	CR,"BAD HEADER",CR,00H	;
MSG_BADCMD:
	DB	CR,"BAD COMMAND",CR,00H	;
MSG_END:
	DB	CR,"VGM END",CR,00H	;

SAVSP:	DS	2			;SP退避
BLKSZ:	DS	4			;データブロックの残りサイズ
RBUF:		DS	RBUF_SIZE	;先読みリングバッファ
RBUF_END	EQU	$		;バッファ末尾＋1
RB_RDP:		DS	2		;読み出しポインタ
RB_WRP:		DS	2		;書き込みポインタ
RB_CNT:		DS	2		;バッファ内バイト数（0～RBUF_SIZE）
RB_EOF:		DS	1		;先読みが終端に達したら非0

	END
