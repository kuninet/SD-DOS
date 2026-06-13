;=================================================
;ストリーム読み出しAPI
;・仕様は docs/design/api-spec.md を参照
;・呼び出しはMAIN.asm先頭のジャンプテーブル（固定アドレス）を使う
;=================================================

;=================================================
;[STRM]ストリームを開く
;IN  HL=パス文字列の先頭アドレス（00H終端）
;OUT CY=0:成功
;    CY=1:失敗 A=01H:エントリが見つからない
;=================================================
STRM_OPEN:
	XOR	A				;いったん未オープンにする（オープン中なら暗黙クローズ）
	LD	(STRM_STAT),A			;
	LD	A,0FFH			;ストリーム中はSDアクセス音を抑止
	LD	(SD_SND_OFF),A		;
	LD	(ARG0),HL			;(ARG0)<-パス文字列の先頭アドレス
	CALL	CHANGE_WDIR			;パス部があればディレクトリを移動 HL<-エントリ名の先頭
	LD	C,ATRB_FILE			;ファイル属性で
	CALL	GET_DENT			;ディレクトリエントリを検索する
	JR	Z,.NOTFOUND			;
	LD	HL,(DIR_ENTRY+IDX_FAT)		;(TGT_CLSTR)<-ファイルの開始クラスタ＃
	LD	(TGT_CLSTR),HL			;
	LD	HL,DIR_ENTRY+IDX_SIZE		;(STRM_REMAIN)<-ファイルサイズ
	LD	DE,STRM_REMAIN			;
	CALL	DW_COPY				;
	CALL	PREP_READ			;ファイルポインタ初期化と先頭セクタ読み込み
	LD	A,01H				;読み出し中にする
	LD	(STRM_STAT),A			;
	CALL	RESTORE_WDIR			;
	OR	A				;CY<-0
	RET					;

.NOTFOUND:
	XOR	A				;オープン失敗：アクセス音を戻す
	LD	(SD_SND_OFF),A		;
	CALL	RESTORE_WDIR			;
	LD	A,01H				;エントリが見つからない
	SCF					;CY<-1
	RET					;

;=================================================
;[STRM]１バイト取得する
;IN  -
;OUT CY=0:A=取得した値
;    CY=1:A=00H:EOF（正常終了） A=01H:未オープン
;！内部で裏レジスタを使用する！
;=================================================
STRM_READ:
	LD	A,(STRM_STAT)			;
	CP	01H				;読み出し中でなければ
	JR	NZ,.NG				;状態を返す
	EXX					;
	PUSH	IX				;
	CALL	IS_REMAIN_ZERO			;残りバイト数が０なら
	JR	Z,.EOF				;EOF到達にする
	LD	IX,FILE_BFFR_STRCT		;
	CALL	FP2BP				;HL<-FPが示すバッファポインタ
	LD	C,(HL)				;C<-取得した値
	LD	HL,STRM_REMAIN			;残りバイト数を１減らす
	CALL	DW_DEC				;
	CALL	IS_REMAIN_ZERO			;残りが０でなければ
	CALL	NZ,INC_FP			;ファイルポインタを進める ！最終バイトでは進めない！
	LD	A,C				;A<-取得した値
	POP	IX				;
	EXX					;
	OR	A				;CY<-0
	RET					;

.EOF:	LD	A,02H				;EOF到達にする
	LD	(STRM_STAT),A			;
	POP	IX				;
	EXX					;
	LD	A,00H				;A<-EOF
	SCF					;CY<-1
	RET					;

.NG:	CP	02H				;EOF到達済みなら
	LD	A,00H				;A<-EOF
	JR	Z,.NG1				;
	LD	A,01H				;A<-未オープン
.NG1:	SCF					;CY<-1
	RET					;

;=================================================
;[STRM]残りバイト数のゼロ判定
;IN  (STRM_REMAIN)
;OUT Z=1:残りバイト数は０
;=================================================
IS_REMAIN_ZERO:
	PUSH	HL				;
	PUSH	BC				;
	LD	HL,STRM_REMAIN			;
	LD	B,04H				;
	XOR	A				;
.L1:	OR	(HL)				;
	INC	HL				;
	DJNZ	.L1				;
	OR	A				;
	POP	BC				;
	POP	HL				;
	RET					;

;=================================================
;[STRM]ストリームを閉じる
;IN  -
;OUT CY=0
;=================================================
STRM_CLOSE:
	XOR	A				;未オープンにする CY<-0
	LD	(STRM_STAT),A			;
	LD	(SD_SND_OFF),A		;アクセス音を戻す
	RET					;

;=================================================
;[STRM]予約エントリ
;IN  -
;OUT CY=1,A=0FFH:未実装
;=================================================
STRM_RSVD:
	LD	A,0FFH				;未実装
	SCF					;
	RET					;
