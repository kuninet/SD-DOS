;=================================================
;ストリーム読み出しAPI（インクリメンタル読み）
;・仕様は docs/design/api-spec.md と docs/design/streaming-read.md を参照
;・SDのブロック読みを開いたまま1バイトずつクロックし、約0.1秒のバーストを避ける
;・呼び出しはMAIN.asm先頭のジャンプテーブル（固定アドレス）を使う
;=================================================

;=================================================
;[STRM]ストリームを開く
;IN  HL=パス文字列の先頭アドレス（00H終端）
;OUT CY=0:成功
;    CY=1:失敗 A=01H:エントリが見つからない
;=================================================
STRM_OPEN:
	LD	(ARG0),HL		;(ARG0)<-パス文字列の先頭アドレス
	CALL	STRM_ENDBLK		;前回のブロックが開いていれば締める
	XOR	A			;いったん未オープンにする
	LD	(STRM_STAT),A		;
	LD	A,0FFH			;ストリーム中はSDアクセス音を抑止
	LD	(SD_SND_OFF),A		;
	CALL	CHANGE_WDIR		;パス部があればディレクトリを移動
	LD	C,ATRB_FILE		;ファイル属性で
	CALL	GET_DENT		;ディレクトリエントリを検索する
	JR	Z,.NOTFOUND		;
	LD	HL,(DIR_ENTRY+IDX_FAT)	;現在クラスタ<-ファイルの開始クラスタ＃
	LD	(STRM_CLSTR),HL		;
	XOR	A			;クラスタ内セクタ＃=0
	LD	(STRM_CSEC),A		;
	LD	HL,0			;セクタ内オフセット=0
	LD	(STRM_BOFS),HL		;
	LD	HL,DIR_ENTRY+IDX_SIZE	;残りバイト数<-ファイルサイズ
	LD	DE,STRM_REMAIN		;
	CALL	DW_COPY			;
	LD	A,01H			;読み出し中にする
	LD	(STRM_STAT),A		;
	CALL	RESTORE_WDIR		;
	OR	A			;CY<-0
	RET				;

.NOTFOUND:
	XOR	A			;オープン失敗：アクセス音を戻す
	LD	(SD_SND_OFF),A		;
	CALL	RESTORE_WDIR		;
	LD	A,01H			;エントリが見つからない
	SCF				;CY<-1
	RET				;

;=================================================
;[STRM]１バイト取得する
;IN  -
;OUT CY=0:A=取得した値
;    CY=1:A=00H:EOF（正常終了） A=01H:未オープン
;！呼び出し側のBC/DE/HL/IXは保存する！
;=================================================
STRM_READ:
	LD	A,(STRM_STAT)		;
	CP	01H			;読み出し中でなければ
	JR	NZ,.NG			;状態を返す
	PUSH	BC			;呼び出し側レジスタを保存
	PUSH	DE			;
	PUSH	HL			;
	PUSH	IX			;
	CALL	IS_REMAIN_ZERO		;残りバイト数が０なら
	JR	Z,.EOF			;EOF到達にする
	LD	A,(STRM_OPEN_BLK)	;ブロック未オープンなら
	OR	A			;
	CALL	Z,STRM_BLKOPEN		;現在セクタのブロック読みを開く
	CALL	MMC_1RD			;C<-1バイトクロックして取得
	LD	A,C			;取得値を一時退避
	LD	(STRM_TMP),A		;
	LD	HL,STRM_REMAIN		;残りバイト数を１減らす
	CALL	DW_DEC			;
	CALL	STRM_ADVANCE		;セクタ内位置を進める（境界でブロック更新）
	LD	A,(STRM_TMP)		;取得値を復帰
	POP	IX			;
	POP	HL			;
	POP	DE			;
	POP	BC			;
	OR	A			;CY<-0
	RET				;

.EOF:	LD	A,02H			;EOF到達にする
	LD	(STRM_STAT),A		;
	CALL	STRM_ENDBLK		;EOF時に開いているブロックを即閉じる(長時間放置を避ける)
	POP	IX			;
	POP	HL			;
	POP	DE			;
	POP	BC			;
	LD	A,00H			;A<-EOF
	SCF				;CY<-1
	RET				;

.NG:	CP	02H			;EOF到達済みなら
	LD	A,00H			;A<-EOF
	JR	Z,.NG1			;
	LD	A,01H			;A<-未オープン
.NG1:	SCF				;CY<-1
	RET				;

;=================================================
;[STRM]残りバイト数のゼロ判定
;IN  (STRM_REMAIN)
;OUT Z=1:残りバイト数は０
;=================================================
IS_REMAIN_ZERO:
	PUSH	HL			;
	PUSH	BC			;
	LD	HL,STRM_REMAIN		;
	LD	B,04H			;
	XOR	A			;
.L1:	OR	(HL)			;
	INC	HL			;
	DJNZ	.L1			;
	OR	A			;
	POP	BC			;
	POP	HL			;
	RET				;

;=================================================
;[STRM]現在セクタのブロック読みを開く
;IN  (STRM_CLSTR),(STRM_CSEC)
;OUT ブロック読みオープン,(STRM_OPEN_BLK)=非0,(STRM_BOFS)=0
;=================================================
STRM_BLKOPEN:
	LD	HL,(STRM_CLSTR)		;(DW0)<-クラスタの開始セクタ＃
	CALL	GET_FIRST_SCTR		;
	LD	HL,DW1			;(DW1)<-クラスタ内セクタ＃
	CALL	DW_CLR			;
	LD	A,(STRM_CSEC)		;
	LD	(DW1),A			;
	CALL	DW0_ADD			;(DW0)<-開始セクタ＃+クラスタ内セクタ＃=目的セクタ＃
	CALL	GET_PHYSICAL_ADRS	;(MMCADR)<-物理アドレス
	CALL	MMC_BRD_CMD		;ブロック読み開始（LED/音は呼ばない）
	LD	A,0FFH			;
	LD	(STRM_OPEN_BLK),A	;
	LD	HL,0			;
	LD	(STRM_BOFS),HL		;
	RET				;

;=================================================
;[STRM]セクタ内位置を１進める。セクタ末尾でブロックを締めて次セクタ/クラスタへ
;IN  (STRM_BOFS),(STRM_CSEC),(STRM_CLSTR)
;OUT 更新
;=================================================
STRM_ADVANCE:
	LD	HL,(STRM_BOFS)		;セクタ内オフセット++
	INC	HL			;
	LD	(STRM_BOFS),HL		;
	LD	A,H			;512（0200H）に達したか
	CP	02H			;
	RET	NZ			;未到達なら戻る
	CALL	STRM_ENDBLK		;ブロックを締める（残り0なのでCRCのみ）
	LD	HL,0			;セクタ内オフセット=0
	LD	(STRM_BOFS),HL		;
	LD	A,(STRM_CSEC)		;クラスタ内セクタ＃++
	INC	A			;
	LD	(STRM_CSEC),A		;
	LD	HL,SCTRS_PER_CLSTR	;
	CP	(HL)			;クラスタ内に収まるなら戻る
	RET	C			;
	XOR	A			;クラスタ内セクタ＃=0
	LD	(STRM_CSEC),A		;
	LD	HL,(STRM_CLSTR)		;FATをたどって次クラスタへ
	CALL	READ_FAT_DATA		;DE<-次クラスタ＃
	LD	(STRM_CLSTR),DE		;
	RET				;

;=================================================
;[STRM]開いているブロックを締める（残りデータをドレインしてCRC読み）
;IN  (STRM_OPEN_BLK),(STRM_BOFS)
;OUT (STRM_OPEN_BLK)=0
;=================================================
STRM_ENDBLK:
	LD	A,(STRM_OPEN_BLK)	;
	OR	A			;
	RET	Z			;開いていなければ何もしない
	LD	HL,0200H		;残り=512-現在オフセット
	LD	DE,(STRM_BOFS)		;
	OR	A			;CY<-0
	SBC	HL,DE			;
.DL:	LD	A,H			;残りバイトをクロックして読み捨てる
	OR	L			;
	JR	Z,.FIN			;
	CALL	MMC_1RD			;
	DEC	HL			;
	JR	.DL			;
.FIN:	CALL	MMC_BRD_END		;CRC2バイト読み
	XOR	A			;
	LD	(STRM_OPEN_BLK),A	;
	RET				;

;=================================================
;[STRM]ストリームを閉じる
;IN  -
;OUT CY=0
;=================================================
STRM_CLOSE:
	PUSH	BC			;呼び出し側レジスタを保存
	PUSH	DE			;
	PUSH	HL			;
	CALL	STRM_ENDBLK		;開いていればブロックを締める
	XOR	A			;未オープンにする
	LD	(STRM_STAT),A		;
	LD	(SD_SND_OFF),A		;アクセス音を戻す
	POP	HL			;
	POP	DE			;
	POP	BC			;
	OR	A			;CY<-0
	RET				;

;=================================================
;[STRM]予約エントリ
;IN  -
;OUT CY=1,A=0FFH:未実装
;=================================================
STRM_RSVD:
	LD	A,0FFH			;未実装
	SCF				;
	RET				;

;=================================================
;[STRM]ディレクトリ列挙: 現在WDIRのN番目のファイルエントリ名を返す
;IN  DE=インデックス(ファイルエントリのみ0始まり), HL=出力バッファ(13バイト以上)
;OUT CY=0:[HL]="NAME.EXT",00H / CY=1:そのインデックスは無い(末尾超過)
;    破壊 AF,BC,DE,HL,IX,IY
;=================================================
;[STRM]ディレクトリ列挙: 現在WDIRの全ファイル名をバッファへ書き込む(1回走査)
;IN  HL=出力バッファ, B=最大件数(1件13バイト "NAME.EXT",0)
;OUT A=書き込んだ件数(B上限)
;    破壊 AF,BC,DE,HL,IX,IY
;=================================================
STRM_DIRLIST:
	LD	(STRM_DLPTR),HL	;書き込みポインタ
	LD	A,B			;最大件数
	LD	(STRM_DLMAX),A		;
	XOR	A			;件数=0
	LD	(STRM_DLCNT),A		;
	LD	A,0FFH			;列挙中はアクセス音抑止
	LD	(SD_SND_OFF),A		;
	LD	HL,(WDIR_CLSTR)		;現在ディレクトリを1回巡回
	LD	IY,STRM_DLIST_SUB	;
	CALL	DIR_WALK		;
	XOR	A			;
	LD	(SD_SND_OFF),A		;抑止解除
	LD	A,(STRM_DLCNT)		;A<-件数
	RET				;

;[STRM]DIR_WALKコールバック: ファイルエントリ名をバッファへ追記
;IN HL=エントリ先頭 OUT CY=1で巡回終了(上限到達)
STRM_DLIST_SUB:
	CALL	IS_VALID_DENT		;無効はスキップ/EODは終了
	PUSH	HL			;IX<-エントリ
	POP	IX			;
	LD	A,(IX+IDX_ATRB)		;属性
	AND	00011110B		;隠/システム/ボリューム/ディレクトリ→除外
	JR	NZ,.skip		;
	LD	A,(STRM_DLCNT)		;上限到達?
	LD	B,A			;
	LD	A,(STRM_DLMAX)		;
	CP	B			;
	JR	Z,.full			;
	PUSH	IX			;HL<-エントリ名(8.3)
	POP	HL			;
	LD	DE,(STRM_DLPTR)		;出力先
	CALL	STRM_FMT83		;"NAME.EXT",0 を書く
	LD	HL,(STRM_DLPTR)		;ポインタ+13
	LD	DE,0DH			;
	ADD	HL,DE			;
	LD	(STRM_DLPTR),HL		;
	LD	A,(STRM_DLCNT)		;件数++
	INC	A			;
	LD	(STRM_DLCNT),A		;
.skip:	OR	A			;CY<-0(継続)
	RET				;
.full:	SCF				;CY<-1(上限で終了)
	RET				;


;[STRM]8.3名(11バイト)を "NAME.EXT",00H へ整形
;IN HL=8.3名(src), DE=出力(dst)
STRM_FMT83:
	PUSH	HL			;src退避
	LD	B,08H			;名前部 最大8文字
.nm:	LD	A,(HL)			;
	CP	20H			;空白で打ち切り
	JR	Z,.nmd			;
	LD	(DE),A			;
	INC	DE			;
	INC	HL			;
	DJNZ	.nm			;
.nmd:	POP	HL			;src先頭
	LD	BC,08H			;HL<-拡張子先頭(src+8)
	ADD	HL,BC			;
	LD	A,(HL)			;拡張子が空白なら拡張子なし
	CP	20H			;
	JR	Z,.end			;
	LD	A,2EH			;"."
	LD	(DE),A			;
	INC	DE			;
	LD	B,03H			;拡張子 最大3文字
.ex:	LD	A,(HL)			;
	CP	20H			;
	JR	Z,.end			;
	LD	(DE),A			;
	INC	DE			;
	INC	HL			;
	DJNZ	.ex			;
.end:	XOR	A			;00H終端
	LD	(DE),A			;
	RET				;




;=================================================
;[STRM]Create write stream (new/overwrite)
;IN  HL=filename ptr ("NAME.EXT",00H)
;OUT CY=0  (caller responsibility: not call while STRM_OPEN active)
;=================================================
STRM_CREATE:
	LD	(ARG0),HL
	LD	A,0FFH
	LD	(SD_SND_OFF),A
	LD	C,ATRB_FILE
	CALL	PREP_DENT
	CALL	IS_READ_ONLY
	CALL	PREP_WRITE
	CALL	RESTORE_WDIR
	OR	A
	RET

;=================================================
;[STRM]Write 1 byte (caller responsibility: STRM_CREATE was called)
;IN  A=byte / OUT CY=0
;Preserves BC/DE/HL via POST_1BYTE EXX. IX saved here.
;=================================================
STRM_WRITE:
	PUSH	IX
	LD	IX,FILE_BFFR_STRCT
	CALL	POST_1BYTE
	POP	IX
	OR	A
	RET

;=================================================
;[STRM]Finalize write stream (caller responsibility: paired with CREATE)
;IN  - / OUT CY=0
;=================================================
STRM_FCLOSE:
	CALL	FIN_WRITE
	CALL	WRITE_DENT
	XOR	A
	LD	(SD_SND_OFF),A
	OR	A
	RET
