#!/bin/bash
# helper.sh — 右键工具箱的特权执行脚本
# 由 Finder Sync 扩展通过 NSUserScriptTask 调用（沙箱内允许执行本目录脚本，且脚本不受沙箱限制）
# 职责：读取扩展写好的命令文件并执行，把输出回写到扩展容器

C="$HOME/Library/Containers/com.user.rightclicktools.RightClickToolsExt/Data"
TMP="$C/tmp"
LOG="$TMP/rc_log.txt"
CMD="$TMP/rc_cmd.sh"
OUT="$TMP/rc_out.txt"

mkdir -p "$TMP"
STAMP="$(date '+%H:%M:%S')"
echo "$STAMP [helper] 收到执行请求" >> "$LOG"

if [ ! -f "$CMD" ]; then
  echo "$STAMP [helper] 命令文件不存在" >> "$LOG"
  exit 1
fi

rm -f "$OUT"
/bin/bash "$CMD" > "$OUT" 2>&1
EXIT_CODE=$?

# 把执行输出摘要进日志（前 10 行）
head -10 "$OUT" 2>/dev/null | sed "s/^/$STAMP [helper输出] /" >> "$LOG"
echo "$STAMP [helper] 完成 exit=$EXIT_CODE" >> "$LOG"
exit $EXIT_CODE
