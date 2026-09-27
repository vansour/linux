#!/usr/bin/env bash
# ============================================================
# build.sh —— 把多文件源码打包成单文件 install.sh
#
# 开发时用模块化的 main.sh + lib/ + modules/，
# 分发给用户时只需要一个 install.sh：
#
#   bash <(curl -sL https://example.com/install.sh)
#   curl -sL https://example.com/install.sh | sudo bash
#
# 改完源码记得重新跑一次: bash build.sh
# ============================================================

set -euo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-$ROOT/install.sh}"

LIBS=(core ui module registry)

# 删掉被拼接文件的 shebang，只保留最终文件开头的那个
_strip_shebang() {
    sed '1{/^#!/d;}' "$1"
}

# ------------------------------------------------------------
# 收集输入文件（按载入顺序）
# ------------------------------------------------------------
_src_files=()
for lib in "${LIBS[@]}"; do
    f="$ROOT/lib/$lib.sh"
    [[ -r "$f" ]] || { printf '缺少源文件: %s\n' "$f" >&2; exit 1; }
    _src_files+=("$f")
done

shopt -s nullglob
_module_files=("$ROOT"/modules/*.sh)
shopt -u nullglob

(( ${#_module_files[@]} )) || { printf 'modules/ 下没有模块文件\n' >&2; exit 1; }
_src_files+=("${_module_files[@]}")
_src_files+=("$ROOT/main.sh")

# ------------------------------------------------------------
# 生成
#
# 先写到临时文件，全部自检通过后才落到 $OUT。直接写 $OUT 的话，
# 校验失败会在工作区留下一个损坏的 install.sh —— 提交虽然被钩子拦下，
# 坏产物却还在，容易被后续操作误带上。
# ------------------------------------------------------------
_TMP_OUT="$OUT.tmp.$$"
trap 'rm -f "$_TMP_OUT"; rm -rf "${_isolated:-}"' EXIT

{
    printf '#!/usr/bin/env bash\n'
    printf '# ============================================================\n'
    printf '#  Linux 一键配置脚本 —— 单文件版（自动生成，请勿直接编辑）\n'
    printf '#\n'
    printf '#  不写入生成时间：产物需完全可复现，否则 pre-commit 钩子\n'
    printf '#  每次重建都会产生无意义的 diff。构建时间看 git log。\n'
    printf '#  源码改动请编辑 main.sh / lib/ / modules/，然后运行 bash build.sh\n'
    printf '# ============================================================\n'
    printf 'SINGLE_FILE=1\n'
    printf 'SELF_NAME="install.sh"\n'

    for f in "${_src_files[@]}"; do
        rel="${f#"$ROOT"/}"
        printf '\n\n# ════════════════════════════════════════════════════════════\n'
        printf '#  ↓↓↓ 内联自 %s\n' "$rel"
        printf '# ════════════════════════════════════════════════════════════\n'
        _strip_shebang "$f"
    done
} >"$_TMP_OUT"

chmod +x "$_TMP_OUT"

# ------------------------------------------------------------
# 打包后自检（全部针对临时文件，失败不污染工作区）
# ------------------------------------------------------------
if ! bash -n "$_TMP_OUT"; then
    printf '打包结果语法错误，已保留原 %s 不变\n' "$(basename "$OUT")" >&2
    exit 1
fi

# 隔离验证：把产物单独复制到空目录运行。
# 只要它还能正常列出全部模块，就证明确实不依赖 lib/ 和 modules/。
# （比 grep source 语句可靠：. /etc/os-release 这类正当调用不会被误判）
_isolated="$(mktemp -d)"
cp "$_TMP_OUT" "$_isolated/install.sh"

_expected="${#_module_files[@]}"
_list_out="$(cd "$_isolated" && bash ./install.sh --list 2>&1)" || {
    printf '隔离运行失败:\n%s\n' "$_list_out" >&2
    exit 1
}
_registered="$(printf '%s\n' "$_list_out" | grep -oE '已注册 [0-9]+ 个模块' | grep -oE '[0-9]+')"
if [[ "$_registered" != "$_expected" ]]; then
    printf '隔离运行异常: 期望注册 %s 个模块，实际 %s\n' "$_expected" "${_registered:-0}" >&2
    printf '%s\n' "$_list_out" >&2
    exit 1
fi

# ------------------------------------------------------------
# 自检全部通过，此刻才落到目标位置
# ------------------------------------------------------------
mv -f "$_TMP_OUT" "$OUT"
chmod +x "$OUT"

_lines="$(wc -l <"$OUT")"
_size="$(du -h "$OUT" | cut -f1)"
printf '✓ 打包完成: %s\n' "$OUT"
printf '  %s 行, %s, 内联 %d 个文件\n' "$_lines" "$_size" "${#_src_files[@]}"
printf '  运行: sudo bash %s\n' "$(basename "$OUT")"
