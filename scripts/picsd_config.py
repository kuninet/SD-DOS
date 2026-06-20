#!/usr/bin/env python3
"""PICSD版ビルド用: コピーした LABELS.asm の USE_PICSD を TRUE に書き換える。

`make picsd` が out-of-tree のソースコピー(build/picsd-src/)に対して実行する。
コミット済みの src/LABELS.asm は一切変更しない(既定=ビットバンギング)。

.asm は Shift-JIS(cp932)/CRLF。USE_PICSD 行は ASCII のみなので、
その行の FALSE だけを TRUE に置き換える(エンコーディング安全)。
"""
import sys


def main():
    if len(sys.argv) != 2:
        print("usage: picsd_config.py <LABELS.asm>", file=sys.stderr)
        sys.exit(2)
    path = sys.argv[1]
    raw = open(path, "rb").read()
    text = raw.decode("cp932")
    # CRLF を保ったまま行分割
    sep = "\r\n" if "\r\n" in text else "\n"
    lines = text.split(sep)
    hit = False
    for i, ln in enumerate(lines):
        if ln.startswith("USE_PICSD") and "FALSE" in ln:
            lines[i] = ln.replace("FALSE", "TRUE", 1)
            hit = True
            break
    if not hit:
        print("error: USE_PICSD ... FALSE line not found in %s" % path, file=sys.stderr)
        sys.exit(1)
    open(path, "wb").write(sep.join(lines).encode("cp932"))
    print("picsd_config: USE_PICSD=TRUE -> %s" % path)


if __name__ == "__main__":
    main()
