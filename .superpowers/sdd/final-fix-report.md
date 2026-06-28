# Final Fix Report — sysctl-helper.sh

## Fix 1 (Critical): grep -c || echo double-output bug

**Problem:** `grep -c` outputs "0" and exits with code 1 when it finds zero matches, triggering
`|| echo "0"` (or `|| echo "?"`) which appends a second value. The variable gets `0\n0`, causing bash
arithmetic errors downstream.

**Locations fixed (4 total):**

| Line (original) | Context | Change |
|---|---|---|
| ~243 | `func_enable_bbr_stage3_verify` → `bbr_conns` | `|| echo "0"` → `|| true` |
| ~657 | `func_remove_keys_scan` → `key_count` (root) | `|| echo "?"` → `|| true` |
| ~669 | `func_remove_keys_scan` → `cnt` (other users) | `|| echo "?"` → `|| true` |
| ~1039 | `func_show_status` → `ak_count` | `|| echo "0"` → `|| true` |

Each file path is guarded by an `[[ -f ... ]]` check before the grep, so `|| true` is safe — grep -c
already outputs `"0"` on zero matches, and only a real I/O error would produce an empty string (which
is acceptable as the surrounding conditionals handle that).

---

## Fix 2 (Important): SSH restart exit silently swallowed

**Problem:** In `func_enable_root_login` and `func_remove_keys`, the SSH restart line was:
```bash
systemctl restart "$sshd_svc" 2>/dev/null || systemctl restart ssh 2>/dev/null
```
If both restarts fail, `set -e` kills the script with no error message. Function 3 already handled
this correctly with a `|| { msg_err …; return; }` fallback block.

**Fix:** Both functions now match function 3's pattern:
```bash
systemctl restart "$sshd_svc" 2>/dev/null || systemctl restart ssh 2>/dev/null || {
    msg_err "SSH 服务重启失败！请手动检查配置"
    return
}
```
Also added the missing `msg_ok "sshd_config 语法检查通过"` line before the restart in both functions.

Files changed:
- `func_enable_root_login` (~line 625)
- `func_remove_keys` (~line 893)

---

## Fix 3 (Minor): _comment_key defined but never called

**Problem:** `func_enable_root_login` defined an 8-line `_comment_key()` helper function that was
never invoked anywhere in the script.

**Fix:** Removed the entire function definition (lines 546–553 in the original).

---

## Fix 4 (Minor): Dead variable use_chrony

**Problem:** In `func_enable_ntp`, `local use_chrony=0` was assigned but never read.

**Fix:** Removed the line.

---

## Fix 5 (Minor): Dead variable name in scan loop

**Problem:** In `func_remove_keys_scan`, inside the drop-in directory scan loop,
`local name` and `name=$(basename "$f")` were assigned but never used.

**Fix:** Removed both lines.

---

## Fix 6 (Cosmetic): Comment typo

**Problem:** Comment on the `_set_or_comment` helper in `func_remove_keys` was missing a closing `)`:
```
# 辅助函数（复用功能4的模式
```

**Fix:** Changed to:
```
# 辅助函数（复用功能4的模式）
```

---

## Syntax Check Result

```
$ bash -n /root/github/linux/sysctl-helper.sh
(no output — exit code 0)
```

**PASS** — no syntax errors.
