;=================================================
;VGMIRQ - 割り込み駆動VGM再生サンプル(YM2203 Timer A)
;=================================================
;・SD上の*.VGM(無圧縮)を一覧表示し、番号で選んでストリーム読み出しAPIで
;  読みながら、YM2203ボード(80H/81H)とPSGボード(0A0H/0A1H)へ出力する
;・ウェイトコマンドはYM2203 Timer AによるZ80 IM 2割り込みで刻む(VGMPLAYの
;  WAIT_KV/DJNZ方式を置き換え)。HALTでCPUを寝かせる
;・I=80HのままPC-8001の$8000台RAM上のIM2ベクタテーブルを使う(N-BASIC
;  起動時にRAMへ展開される)。INT4..7のうち空き1本に対応するvectorエントリ
;  2バイトだけを再生開始時に自前ISRで上書きし、終了時に元値を復元
;・232C拡張ボードの8251用エントリ($8008/$800A)には触らないため、シリアル
;  受信割り込みと共存できる
;・ISRはTimer A flagリセット+tickフラグONのみ。SD/シリアル/PUTSは触らない
;・SD補充はHALT直前にメインでRB_TRYFILL1をFILL_BURST回まで
;・使い方: LOAD "VGMIRQ.CMT" :(必要ならCD): モニタG9000
;   現在ディレクトリの*.VGM一覧 → 番号+Enterで再生 → 0/Enterで終了
;・POKE点: 9003H=IVR_FMTAV(vector番号) 9004H=FILL_BURSTV(補充回数)
;         9005H/9006H=TPSV_LO/TPSV_HI(TICKS_PER_SAMPLE 校正値、16bit、テンポ調整)
;・実機確認(Phase 0)で校正する定数: IVR_FMTA_DEFAULT, TICKS_PER_SAMPLE_X256
;・ヘッダ=header.md コマンド=commands.md 入出力=sound-io.md (docs/vgm/)
;=================================================

STRM_OPEN	EQU	6005H		;ストリームを開く
STRM_READ	EQU	6008H		;1バイト取得
STRM_CLOSE	EQU	600BH		;ストリームを閉じる
STRM_DIRLIST	EQU	600EH		;ディレクトリ一括取得

OPN_ADDR	EQU	80H		;YM2203 レジスタ番号/ステータス
OPN_DATA	EQU	81H		;YM2203 データ
PSG_ADDR	EQU	0A0H		;PSG#1 レジスタ番号
PSG_DATA	EQU	0A1H		;PSG#1 データ

CR		EQU	0DH
LF		EQU	0AH
BASIC		EQU	0081H		;BASIC復帰(モニタG/直接実行どちらでも安全)
KEYWAIT		EQU	0F75H		;1文字入力待ち A<-コード
MAXFILES	EQU	40H		;一覧の最大ファイル数(64)

;--- YM2203 Timer A レジスタ (docs/vgm/sound-io.md / YM2203 datasheet) ---
;27Hビット配置: bit0=LoadA, bit1=LoadB, bit2=IRQEN A, bit3=IRQEN B,
;               bit4=ResetA, bit5=ResetB, bit7:6=CH3 mode
TA_REG_HI	EQU	24H		;Timer A 高位8bit
TA_REG_LO	EQU	25H		;Timer A 低位2bit
TA_REG_CTRL	EQU	27H		;モード/制御
TA_CTRL_RUN_IRQEN	EQU	00000101B	;LoadA=1, IRQEN A=1
TA_CTRL_STOP_RESET	EQU	00010000B	;ResetA=1
TA_FLAG_RESET_A_MASK	EQU	00010000B	;bit4 (Timer A flag reset)

;--- VGMサンプル -> Timer A tick 変換 ---
;1サンプル = 1/44100s ≒ 22.676us
;YM2203 Timer A 1 tick = 72/master_clock
; ・実機マスタークロック 3.579545MHz の場合 → 1 tick ≒ 20.11us
;ticks_per_sample = 22.676 / 20.11 ≒ 1.128
;*256固定小数: round(1.128 * 256) = 289 = 0x121 = 256 + 32 + 1
TICKS_PER_SAMPLE_X256	EQU	289
MAX_SAMPLES_PER_CHUNK	EQU	512
MAX_CHUNK_HI	EQU	02H		;512の高位
MAX_CHUNK_LO	EQU	00H		;512の低位
;LONG分岐のNAは静的固定値ではなく CALC_TA_CHUNK 内で動的に
;(512 × TPSV / 256) で計算する。これにより 9005H POKE が
;LONG 分岐にも反映される(VGM 62H=735 / 63H=882 の主要部)。

;--- IM2 ベクタテーブル ($8000台RAM、N-BASICが配置) ---
IVT_PAGE	EQU	80H		;Iレジスタ値(=テーブルページ)
IVR_FMTA_DEFAULT	EQU	04H	;INT4..7のうちFM Timer A用に選んだvector
				;Phase 0 の実機計測で確定する
;実エントリ番地は 8000H + (IVR_FMTAV) を起動時に計算

;--- リングバッファ ---
;末尾がN-BASIC高位ワーク領域に食い込まないようVGMPLAYより少し小さめにする
;(ISR/Timer A処理でコードが大きくなった分の埋め合わせ)
RBUF_SIZE	EQU	4500H		;約17.25KB
INITFILL	EQU	2000H		;起動時部分プリフィル(8KB)
RBUF_HIWATER	EQU	RBUF_SIZE - 0100H
FILL_BURST	EQU	04H
FILL_MINSAMP	EQU	40H		;チャンクがこの値未満なら SD 補充スキップ(短wait保護)
FILL_LWMARK	EQU	0AH		;リングバッファ残量がこの値未満(高位8bit比較)で強制補充

	ORG	9000H

	JP	START			;9000H 実行エントリ(モニタG9000)
IVR_FMTAV:	DB	IVR_FMTA_DEFAULT	;9003H POKE: FM Timer A IRQ vector番号
FILL_BURSTV:	DB	FILL_BURST	;9004H POKE: HALT前の補充回数上限(0で完全停止)
TPSV_LO:	DB	33		;9005H POKE: TICKS_PER_SAMPLE_X256 の低位 (=33で289)
TPSV_HI:	DB	1		;9006H POKE: TICKS_PER_SAMPLE_X256 の高位 (=1で +256)
FILL_MINSAMPV:	DB	FILL_MINSAMP	;9007H POKE: チャンクサンプル数下限(これ未満は補充スキップ)
FILL_LWMARKV:	DB	FILL_LWMARK	;9008H POKE: バッファ残量下限(*256bytes 単位、未満で強制補充)
				;・テンポ調整(9005H): 大きくするとテンポが遅くなる、小さくすると速くなる
				;・SD補充頻度(9007H/9008H): 短wait連発で律速されるなら 9007H を増やす(64→128等)
				;  バッファ枯渇するなら 9008H を増やす(10→20等)、9004Hを増やす(4→8等)

START:
	LD	(SAVSP),SP		;BASIC復帰用のSP保存
	LD	SP,STACK_TOP		;専用スタックへ

MENU:
	CALL	BUILD_LIST		;*.VGM一覧表示、(LISTCNT)=件数
	LD	A,(LISTCNT)		;0件なら終了
	OR	A
	JP	Z,BASIC
	CALL	READ_NUM		;HL=入力番号(1始まり、0/EnterでBASICへ)
	LD	A,H			;256以上は無視して再表示
	OR	A
	JR	NZ,MENU
	LD	A,L
	OR	A
	JP	Z,BASIC			;0で終了
	LD	A,(LISTCNT)		;番号>件数なら再表示
	CP	L
	JR	C,MENU
	LD	A,L			;K番目(1始まり)のVGMを選択
	CALL	GET_NTH_VGM		;PLAYNAMEへ
	JR	C,MENU
	CALL	PLAY_FILE		;再生(終了でここへ戻る)
	JR	MENU

;-------------------------------------------------
;正常終了(再生終了/EOF)
;-------------------------------------------------
DONE:
	LD	SP,(PLAYSP)		;再生中の脱出点へ
	CALL	IRQ_TEARDOWN		;割り込み環境を元に戻す
	CALL	STRM_CLOSE
	LD	HL,MSG_END
	CALL	PUTS
	RET				;メニューへ戻る

;-------------------------------------------------
;異常終了
;IN  HL=メッセージ
;-------------------------------------------------
ABORT:
	LD	SP,(PLAYSP)		;再生中の脱出点へ
	PUSH	HL
	CALL	IRQ_TEARDOWN
	CALL	STRM_CLOSE
	POP	HL
	CALL	PUTS
	RET				;メニューへ戻る

;-------------------------------------------------
;BREAK時の中断
;-------------------------------------------------
ABORT_BREAK:
	LD	HL,MSG_BRK
	JP	ABORT

;-------------------------------------------------
;ヘッダ解析(docs/vgm/header.md の最小限の範囲)
;・識別子を確認し、バージョンからデータ開始位置を求めて読み進める
;-------------------------------------------------
PARSE_HDR:
	LD	HL,IDENT		;識別子 "Vgm " の確認
	LD	B,4
.ID:	CALL	GETB
	CP	(HL)
	JR	NZ,.NOTVGM
	INC	HL
	DJNZ	.ID
	LD	DE,4			;04H-07H(EOFオフセット)を読み捨て
	CALL	SKIP
	CALL	GETB			;08H- バージョン(BCD) 下位ワード
	LD	C,A
	CALL	GETB
	LD	B,A			;BC=バージョン下位ワード
	CALL	GETB			;上位2バイトは読み捨て
	CALL	GETB
	LD	H,B			;バージョン1.50未満なら旧形式
	LD	L,C
	LD	DE,0150H
	OR	A
	SBC	HL,DE
	JR	C,.OLD
	LD	DE,0028H		;0CH-33Hを読み捨て
	CALL	SKIP
	CALL	GETB			;34H- データ開始オフセット
	LD	E,A
	CALL	GETB
	LD	D,A			;DE=オフセット下位ワード
	CALL	GETB			;上位2バイトが0以外なら異常
	LD	C,A
	CALL	GETB
	OR	C
	JR	NZ,.BADHDR
	EX	DE,HL			;残読み捨て先=オフセット-4(38Hまで読み済み)
	LD	DE,4
	OR	A
	SBC	HL,DE
	JR	C,.BADHDR		;オフセットが4未満なら異常
	EX	DE,HL
	JP	SKIP			;データ開始位置まで読み捨てて戻る

.OLD:	LD	DE,0034H		;旧形式はデータ開始40H固定。0CH-3Fを読み捨て
	JP	SKIP

.NOTVGM:	LD	HL,MSG_NOTVGM
	JP	ABORT
.BADHDR:	LD	HL,MSG_BADHDR
	JP	ABORT

;-------------------------------------------------
;再生ループ(docs/vgm/commands.md のコマンド表)
;-------------------------------------------------
PLAY:
.LOOP:	CALL	CHECK_BREAK
	CALL	GETB			;コマンド取得
	CP	66H			;終了コマンド
	JP	Z,DONE
	CP	55H			;YM2203書き込み
	JR	Z,.OPN
	CP	0A0H			;PSG書き込み
	JR	Z,.PSG
	CP	61H			;ウェイト(サンプル数指定)
	JR	Z,.W61
	CP	62H			;ウェイト(735サンプル=1/60s)
	JR	Z,.W62
	CP	63H			;ウェイト(882サンプル=1/50s)
	JR	Z,.W63
	LD	C,A			;C<-コマンド退避
	AND	0F0H
	CP	70H			;70H-7FH 短ウェイト
	JR	Z,.W7X
	CP	80H			;80H-8FH YM2612 DAC+ウェイト(対象外なので無視)
	JR	Z,.LOOP
	LD	A,C
	JP	SKIP_CMD		;その他は読み飛ばし規定で

.OPN:	CALL	GETB			;レジスタ番号
	LD	(OPNREG),A
	CALL	GETB			;データ値
	LD	(OPNDAT),A
.BUSY:	IN	A,(OPN_ADDR)		;BUSY(bit7)が下がるまで
	RLCA
	JR	C,.BUSY
	LD	A,(OPNREG)		;レジスタ番号を出力
	OUT	(OPN_ADDR),A
	LD	A,(OPNREG)		;ダミー読みで短い待ち
	LD	A,(OPNDAT)		;データ値を出力
	OUT	(OPN_DATA),A
	JP	PLAY.LOOP

.PSG:	CALL	GETB			;レジスタ番号を出力
	OUT	(PSG_ADDR),A
	CALL	GETB			;データ値を出力
	OUT	(PSG_DATA),A
	JP	PLAY.LOOP

.W61:	CALL	GETB			;DE<-サンプル数
	LD	E,A
	CALL	GETB
	LD	D,A
	CALL	WAIT_DE_HALT
	JP	PLAY.LOOP
.W62:	LD	DE,735			;1/60秒
	CALL	WAIT_DE_HALT
	JP	PLAY.LOOP
.W63:	LD	DE,882			;1/50秒
	CALL	WAIT_DE_HALT
	JP	PLAY.LOOP
.W7X:	LD	A,C			;(下位4bit+1)サンプル
	AND	0FH
	INC	A
	LD	E,A
	LD	D,0
	CALL	WAIT_DE_HALT
	JP	PLAY.LOOP

;-------------------------------------------------
;未対応コマンドの読み飛ばし(docs/vgm/commands.md の規定)
;IN  A=コマンド
;-------------------------------------------------
SKIP_CMD:
	CP	30H			;00H-2FH:未知
	JR	C,.BAD
	CP	40H			;30H-3FH:1バイト
	JR	C,.S1
	CP	4FH			;40H-4EH:未知
	JR	C,.BAD
	CP	51H			;4FH,50H:1バイト
	JR	C,.S1
	CP	60H			;51H-5FH:2バイト
	JR	C,.S2
	CP	64H			;64H:3バイト
	JR	Z,.S3
	CP	67H			;67H:データブロック
	JR	Z,.BLK
	CP	90H			;60H,65H,68H-6FH:未知
	JR	C,.BAD
	CP	96H			;90H-95H:DACストリーム
	JR	C,.S9X
	CP	0A1H			;96H-A0H:未知
	JR	C,.BAD
	CP	0C0H			;A1H-BFH:2バイト
	JR	C,.S2
	CP	0E0H			;C0H-DFH:3バイト
	JR	C,.S3
.S4:	CALL	GETB			;E0H-FFH:4バイト
.S3:	CALL	GETB
.S2:	CALL	GETB
.S1:	CALL	GETB
	JP	PLAY.LOOP

.BAD:	LD	HL,MSG_BADCMD		;未知コマンドは解釈失敗で中断
	JP	ABORT

.S9X:	SUB	90H			;90H-95Hのオペランド数テーブルを参照
	LD	HL,TBL9X
	LD	E,A
	LD	D,0
	ADD	HL,DE
	LD	B,(HL)
.S9L:	CALL	GETB
	DJNZ	.S9L
	JP	PLAY.LOOP

.BLK:	CALL	GETB			;66H(互換用バイト)
	CALL	GETB			;ブロックタイプ
	LD	HL,BLKSZ		;サイズ4バイト(リトルエンディアン)
	LD	B,4
.BSZ:	CALL	GETB
	LD	(HL),A
	INC	HL
	DJNZ	.BSZ
.BSKIP:	LD	HL,BLKSZ		;サイズが0になるまで読み捨て
	LD	B,4
	XOR	A
.BZ:	OR	(HL)
	INC	HL
	DJNZ	.BZ
	OR	A
	JP	Z,PLAY.LOOP
	LD	HL,BLKSZ		;サイズを1減らす(4バイトの繰り下げ)
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
;指定バイト数の読み捨て
;IN  DE=バイト数
;-------------------------------------------------
SKIP:	LD	A,D
	OR	E
	RET	Z
	CALL	GETB
	DEC	DE
	JR	SKIP

;-------------------------------------------------
;1バイト取得(EOFは再生終了として扱う)
;OUT A=取得した値
;-------------------------------------------------
GETB:	PUSH	HL			;HL/DE/BCを保存(呼び出し側でHLを多用)
	PUSH	DE
	PUSH	BC
	CALL	RB_GET			;リングバッファから取得
	JR	NC,.GOT
	LD	A,(RB_EOF)		;バッファ空かつ先読みが終端に達していれば
	OR	A
	JR	NZ,.EOF			;再生終了へ
	CALL	STRM_READ		;フォールバック:直接読み(空かつ終端でない)
	JR	C,.RDEOF
.GOT:	POP	BC
	POP	DE
	POP	HL
	RET				;A=取得した値
.RDEOF:	LD	A,0FFH			;直接読みでEOF
	LD	(RB_EOF),A
.EOF:	POP	BC
	POP	DE
	POP	HL
	JP	DONE			;EOFは再生終了

;-------------------------------------------------
;BREAKチェック(現状は何もしない。STOPキーはN-BASIC側のISRが拾う)
;-------------------------------------------------
CHECK_BREAK:
	RET

;=================================================
;WAIT_DE_HALT - Timer A割り込みでDEサンプル分待つ
; IN: DE = サンプル数
;=================================================
WAIT_DE_HALT:
.LOOP:	LD	A,D
	OR	E
	RET	Z

	CALL	CALC_TA_CHUNK		;OUT: BC=今回消費, HL=NA, DE=残り

	;新NAを確実に効かせるため Timer A を一度停止+flagクリアしてから
	;プリロードを書き換え、Reset→Start で再起動する
	;(走行中に24H/25Hを書き換えても次のoverflowまで反映されないため、
	; 最初のHALTが前ループの残り時間で抜けてテンポが乱れる対策)
	CALL	TA_STOP
	CALL	TA_LOAD_HL		;24H/25Hへ書き込み

	XOR	A
	LD	(TA_TICK),A

	CALL	TA_START		;27H <- LoadA|IRQEN A

	CALL	RB_FILL_OPPORTUNISTIC	;HALT前にSD補充

	EI
	HALT				;Timer A IRQで起きる

	LD	A,(TA_TICK)
	OR	A
	JR	Z,.WAGAIN
	JR	.LOOP
.WAGAIN:
	EI
	HALT
	JR	.LOOP

;-------------------------------------------------
;CALC_TA_CHUNK - 残りサンプル数からTimer Aプリロード値を決める
; IN  DE = 残りサンプル数(16bit)
; OUT BC = 今回消費するサンプル数
;     HL = Timer A 10bitプリロード値(NA)
;     DE = 残り - BC
;-------------------------------------------------
CALC_TA_CHUNK:
	;DE >= MAX_SAMPLES_PER_CHUNK なら最大チャンクで割る
	LD	A,D
	CP	MAX_CHUNK_HI
	JR	C,.SHORT
	JR	NZ,.LONG
	LD	A,E
	CP	MAX_CHUNK_LO
	JR	C,.SHORT
.LONG:
	;DE>=512 のときは MAX_SAMPLES_PER_CHUNK ぶんを 1 チャンクで消費する。
	;NA は固定値 NA_MAX_CHUNK ではなく、TPSV を反映した動的計算にする
	;(POKE で TPSV_LO を変えたら LONG 分岐の wait もテンポに追従するため)
	PUSH	DE			;元の残り(=入力DE)を保存
	LD	D,02H
	LD	E,00H			;DE = MAX_SAMPLES_PER_CHUNK (= 512)
	CALL	MUL_DE_TPS		;HL = (512 × TPS) >> 8 (DEは復元される)
	;NA = 1024 - HL
	PUSH	HL
	LD	HL,1024
	POP	DE
	OR	A
	SBC	HL,DE			;HL = NA
	;NAが0以下なら1にクランプ
	LD	A,H
	OR	A
	JR	NZ,.lOK
	LD	A,L
	OR	A
	JR	NZ,.lOK
	LD	HL,1
.lOK:
	;DE = 元の残り - 512、BC = 512
	POP	DE			;元の残りを復元
	LD	BC,MAX_SAMPLES_PER_CHUNK
	PUSH	HL			;NA を退避
	LD	HL,0
	LD	A,E
	SUB	C
	LD	L,A
	LD	A,D
	SBC	A,B
	LD	H,A
	EX	DE,HL			;DE = 残り - 512
	POP	HL			;HL = NA
	RET

.SHORT:
	;tick = DE * (TPSV_HI:TPSV_LO の16bit値) / 256
	;BC = DE(消費), HL = 1024 - tick, DE = 0
	LD	B,D
	LD	C,E			;BC = DE(退避)
	CALL	MUL_DE_TPS		;HL = (DE * TPS) >> 8 (TPS は 9005/9006 から読む)
	;NA = 1024 - HL
	PUSH	HL
	LD	HL,1024
	POP	DE
	OR	A
	SBC	HL,DE
	;NAが0以下なら1にクランプ(理屈上起きないが保険)
	LD	A,H
	OR	A
	JR	NZ,.OK
	LD	A,L
	OR	A
	JR	NZ,.OK
	LD	HL,1
.OK:
	LD	DE,0			;残り = 0 (DEは乗算で壊している)
	RET

;-------------------------------------------------
;MUL_DE_TPS - HL = (DE * TPS) >> 8
; TPS は 9005H/9006H に置かれた 16bit 値 (POKE 校正可能)
; ・前提: TPSV_HI=1 固定 (実機 3.579545MHz 想定で十分)
;   → HL = DE + (DE * TPSV_LO) >> 8
; ・DE <= 511, TPSV_LO <= 255 で DE*TPSV_LO <= 130305 (17bit)
;   17bit キャリーを A に取り込んでから >>8 する
; IN  : DE
; OUT : HL
; 破壊: AF, BC。DE は保存
;-------------------------------------------------
MUL_DE_TPS:
	PUSH	BC
	PUSH	DE
	LD	A,(TPSV_LO)
	LD	C,A			;C = TPSV_LO (8bit 乗数)
	LD	HL,0			;HL = 累算下位
	XOR	A			;A = 累算上位 (DE*Cの17/24bit用)
	LD	B,8
.lp:
	ADD	HL,HL
	ADC	A,A			;24bit累算: A:HL <<= 1
	SLA	C
	JR	NC,.skip
	ADD	HL,DE
	ADC	A,0			;桁上がりを A に取り込む
.skip:
	DJNZ	.lp
	;A:HL = DE × TPSV_LO (最大18bit想定だが実用上17bit)
	;>>8 : 結果の上位16bit を HL に
	LD	L,H
	LD	H,A
	POP	DE
	;HL += DE (TPSV_HI=1 ぶん)
	ADD	HL,DE
	POP	BC
	RET

;-------------------------------------------------
;OPN_WR_RD - YM2203 1レジスタ書込(BUSY待ち入り)
; IN  : D = レジスタ番号, E = データ
; OUT : 引数なし
; 破壊: AF のみ。BC/DE/HL は不変
;-------------------------------------------------
OPN_WR_RD:
	PUSH	AF
.busy:	IN	A,(OPN_ADDR)
	RLCA
	JR	C,.busy
	LD	A,D
	OUT	(OPN_ADDR),A
	LD	A,D			;ダミー命令で短い待ち
	LD	A,E
	OUT	(OPN_DATA),A
	POP	AF
	RET

;-------------------------------------------------
;TA_LOAD_HL - 24H/25HへTimer A 10bitプリロードを書く(BUSY待し入り)
; IN  : HL = プリロード値(0..1023)
; OUT : 引数なし
; 破壊: AF のみ。BC/DE/HL は呼出側のために保存
;       (CALC_TA_CHUNK が BC=今回サンプル, DE=残り, HL=NA を持って呼ぶため)
; 高位 = HL >> 2 (8bit), 低位 = HL & 3 (下位2bit)
;-------------------------------------------------
TA_LOAD_HL:
	PUSH	BC
	PUSH	DE
	PUSH	HL
	PUSH	AF
	LD	C,L			;Cにオリジナル低位を退避
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
;TA_START - 27H <- LoadA=1, IRQEN A=1(BUSY待し入り)
; IN  : 引数なし
; OUT : 引数なし
; 破壊: AF のみ。BC/DE/HL は不変
;-------------------------------------------------
TA_START:
	PUSH	DE
	LD	D,TA_REG_CTRL
	LD	E,TA_CTRL_RUN_IRQEN
	LD	A,E
	LD	(TA_CTRL_SHADOW),A
	CALL	OPN_WR_RD
	POP	DE
	RET

;-------------------------------------------------
;TA_STOP - Timer Aを停止しflagリセット(BUSY待し入り)
; IN  : 引数なし
; OUT : 引数なし
; 破壊: AF のみ。BC/DE/HL は不変
;-------------------------------------------------
TA_STOP:
	PUSH	DE
	LD	D,TA_REG_CTRL
	LD	E,TA_CTRL_STOP_RESET
	LD	A,E
	LD	(TA_CTRL_SHADOW),A
	CALL	OPN_WR_RD
	;resetパルスを落として通常状態へ
	LD	D,TA_REG_CTRL
	LD	E,0
	XOR	A
	LD	(TA_CTRL_SHADOW),A
	CALL	OPN_WR_RD
	POP	DE
	RET

;-------------------------------------------------
;IRQ_SETUP - ベクタエントリ退避→自前ISR設置→Timer A初期化→EI
;-------------------------------------------------
IRQ_SETUP:
	DI
	;HL = $8000 + (IVR_FMTAV)
	LD	A,(IVR_FMTAV)
	LD	L,A
	LD	H,IVT_PAGE
	LD	(IVT_PTR),HL
	;既存エントリを退避
	LD	E,(HL)
	INC	HL
	LD	D,(HL)
	LD	(SAVED_VEC_FMTA),DE
	;自前ハンドラを書き込み
	LD	HL,(IVT_PTR)
	LD	DE,ISR_FMTA
	LD	(HL),E
	INC	HL
	LD	(HL),D
	;I=80H, IM 2 を確定
	LD	A,IVT_PAGE
	LD	I,A
	IM	2
	;Timer A 初期化: stop+reset → 仮プリロード(初回HALTの保険)
	CALL	TA_STOP
	LD	HL,944			;1024 - 80 ≒ 1.44ms (@18us/tick仮定)
	CALL	TA_LOAD_HL
	EI
	RET

;-------------------------------------------------
;IRQ_TEARDOWN - Timer A停止→ベクタ復元→IM 1へ→EI
;-------------------------------------------------
IRQ_TEARDOWN:
	DI
	CALL	TA_STOP
	;ベクタを元に戻す
	LD	HL,(IVT_PTR)
	LD	DE,(SAVED_VEC_FMTA)
	LD	(HL),E
	INC	HL
	LD	(HL),D
	IM	1
	EI
	RET

;-------------------------------------------------
;ISR_FMTA - 最小ISR。Timer A flagリセット→TA_TICK立て→EI/RETI
;-------------------------------------------------
ISR_FMTA:
	EX	AF,AF'
	PUSH	BC
	;Timer Aオーバーフローflagをパルスリセット
	LD	A,TA_REG_CTRL
	OUT	(OPN_ADDR),A
	LD	A,(TA_CTRL_SHADOW)
	LD	B,A
	OR	TA_FLAG_RESET_A_MASK
	OUT	(OPN_DATA),A
	;制御バイトを戻す(resetパルス解除)
	LD	A,TA_REG_CTRL
	OUT	(OPN_ADDR),A
	LD	A,B
	OUT	(OPN_DATA),A
	;tickフラグを立てる
	LD	A,1
	LD	(TA_TICK),A
	POP	BC
	EX	AF,AF'
	EI
	RETI

;-------------------------------------------------
;RB_FILL_OPPORTUNISTIC - HALT前にリングバッファ補充(スマート版)
;・SD I/O時間がwait短時にHALT待ち時間より長くなる症状の対策
;・判定:
;  (a) リングバッファ残量 < (FILL_LWMARKV * 256) なら強制補充(枯渇防止)
;  (b) チャンクサンプル数(BC) < FILL_MINSAMPV なら補充スキップ(短wait保護)
;  (c) それ以外は通常補充
; IN  : BC = 今回のチャンクサンプル数 (CALC_TA_CHUNK の戻り値)
; OUT : 引数なし
; 破壊: AF のみ。BC/DE/HL は呼出側のために保存
;-------------------------------------------------
RB_FILL_OPPORTUNISTIC:
	PUSH	BC
	PUSH	DE
	PUSH	HL

	;(a) リングバッファ残量チェック (RB_CNT の高位8bit を FILL_LWMARKV と比較)
	LD	HL,(RB_CNT)
	LD	A,(FILL_LWMARKV)
	CP	H			;CY = (FILL_LWMARK < H) → 残量十分
	JR	C,.normal		;残量十分 → (b)判定へ
	JR	NZ,.must_fill		;残量低い → 強制補充
	;H == FILL_LWMARK のときは L で判定(等しい場合は十分側)
	LD	A,L
	OR	A
	JR	NZ,.normal		;Lが0以外なら十分
	JR	.must_fill		;HL==FILL_LWMARK*256 ちょうどなら補充

.normal:
	;(b) チャンクサイズチェック (BC < FILL_MINSAMPV ならスキップ)
	;BC の高位 B が 0 でない (BC >= 256) なら確実に長いチャンク
	LD	A,B
	OR	A
	JR	NZ,.fill_now
	LD	A,(FILL_MINSAMPV)
	CP	C
	JR	NC,.done		;C < FILL_MINSAMP → スキップ
.fill_now:
.must_fill:
	;(c) 通常補充
	LD	A,(FILL_BURSTV)
	OR	A
	JR	Z,.done
	LD	B,A
.lp:	CALL	RB_TRYFILL1
	JR	NC,.done
	DJNZ	.lp
.done:
	POP	HL
	POP	DE
	POP	BC
	RET

;-------------------------------------------------
;リングバッファ操作(VGMPLAY.asmから流用)
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
;PLAY_FILE - OPEN→ヘッダ解析→プリフィル→IRQ設置→PLAY
;=================================================
PLAY_FILE:
	LD	HL,PLAYNAME
	CALL	STRM_OPEN
	JR	C,.nf
	LD	(PLAYSP),SP		;再生中の脱出点
	CALL	RB_INIT
	CALL	PARSE_HDR
	CALL	RB_PREFILL		;部分プリフィル(起動を速く)
	CALL	IRQ_SETUP
	JP	PLAY
.nf:	LD	HL,MSG_NF
	CALL	PUTS
	RET

;=================================================
;*.VGM一覧表示 (VGMPLAY.asmから流用)
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

;=================================================
;HL先頭の名前の拡張子が"VGM"ならZ=1。HLは破壊
;=================================================
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
;10進数入力(数字+Enter)。OUT HL=数値(0=終了)
;=================================================
READ_NUM:
	LD	HL,0
.k:	PUSH	HL
	CALL	KEYWAIT
	POP	HL
	CP	CR
	JR	NZ,.chk			;Enter以外は数字判定
	LD	A,CR			;Enter:改行してから戻る(再生開始前)
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
;A(0-255)の10進表示(先頭ゼロ抑制)
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
IDENT:	DB	"Vgm "			;VGM識別子
TBL9X:	DB	4,4,5,10,1,4		;90H-95Hのオペランド数
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
SAVSP:		DS	2			;SP退避
BLKSZ:		DS	4			;データブロックの残りサイズ
RBUF:		DS	RBUF_SIZE		;先読みリングバッファ
RBUF_END	EQU	$			;バッファ末尾+1
RB_RDP:		DS	2			;読み出しポインタ
RB_WRP:		DS	2			;書き込みポインタ
RB_CNT:		DS	2			;バッファ内バイト数(0..RBUF_SIZE)
RB_EOF:		DS	1			;先読みが終端に達したら0以外
PLAYSP:		DS	2			;再生中の脱出点SP
LISTCNT:	DS	1			;一覧の件数
VGMCNT:		DS	1			;VGM計数(選択用)
TARGETK:	DS	1			;選択された番号(1始まり)
OPNREG:		DS	1			;YM2203レジスタ番号 一時
OPNDAT:		DS	1			;YM2203データ 一時
FILECNT:	DS	1			;全ファイル件数
LISTBUF:	DS	MAXFILES*0DH		;一覧バッファ(1件13バイト)
PLAYNAME:	DS	0DH			;選択ファイル名

;--- 割り込み関連 ---
IVT_PTR:	DS	2			;$8000 + (IVR_FMTAV) をキャッシュ
SAVED_VEC_FMTA:	DS	2			;元のベクタエントリ(2バイト)
TA_TICK:	DS	1			;ISRが1に立てる
TA_CTRL_SHADOW:	DS	1			;27Hに書いた現制御バイト

STACK:		DS	256			;プレイヤー専用スタック
STACK_TOP	EQU	$			;スタック先頭(SPの初期値)

	END
