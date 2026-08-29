#!/usr/bin/env bash
# =====================================================================
# detect.sh - 自动识别谷歌 android16-6.12 内核分支(固定 6.12)
#
# 模式(通过 PATCH_LEVEL 控制):
#   auto / 不设置 = 自动选择最新可用的月度发布分支(含下个月)
#   tip            = android16-6.12 分支头(最新代码, 如 6.12.92)
#   lts            = android16-6.12-lts LTS 分支
#   2026-06 等     = 指定月份(支持 deprecated/ 下的旧分支)
#
# 输出(供 build.sh eval 使用):
#   DETECT_SOURCE_MODE DETECT_MANIFEST_BRANCH DETECT_COMMON_BRANCH
#   DETECT_MONTH DETECT_DEPRECATED DETECT_SUBLEVEL
# 子版本号以 repo sync 后的 common/Makefile 为准, 这里留空。
# =====================================================================
set -euo pipefail

: "${ANDROID_VERSION:=android16}"
: "${KERNEL_VERSION:=6.12}"
: "${PATCH_LEVEL:=auto}"
: "${MIRROR:=ustc}"
: "${MAX_MONTHS_BACK:=9}"

mirror_base() {
    case "$1" in
        ustc)   echo "https://mirrors.ustc.edu.cn/aosp" ;;
        nju)    echo "https://mirror.nju.edu.cn/git/aosp" ;;
        google) echo "https://android.googlesource.com" ;;
        *) echo "错误: 未知 MIRROR=$1 (可选 ustc / google / nju)" >&2; exit 1 ;;
    esac
}

MANIFEST_URL="$(mirror_base "$MIRROR")/kernel/manifest"
COMMON_URL="$(mirror_base "$MIRROR")/kernel/common"

# ls-remote 无匹配也返回 0, 所以要判断输出非空
has_ref() { # $1=url $2=ref 模式
    local out
    out=$(git ls-remote --quiet "$1" "$2" 2>/dev/null || true)
    [ -n "$out" ]
}

emit() { # $1=mode $2=manifest分支 $3=common分支 $4=month $5=deprecated(0/1)
    echo "DETECT_SOURCE_MODE=$1"
    echo "DETECT_MANIFEST_BRANCH=$2"
    echo "DETECT_COMMON_BRANCH=$3"
    echo "DETECT_MONTH=$4"
    echo "DETECT_DEPRECATED=$5"
    echo "DETECT_SUBLEVEL="
}

echo "[detect] 源: $MIRROR  目标: $ANDROID_VERSION-$KERNEL_VERSION  补丁级别: $PATCH_LEVEL" >&2

# ---------- tip ----------
if [ "$PATCH_LEVEL" = "tip" ]; then
    echo "[detect] 使用 android16-6.12 分支头(最新代码)" >&2
    emit tip "common-${ANDROID_VERSION}-${KERNEL_VERSION}" "${ANDROID_VERSION}-${KERNEL_VERSION}" tip 0
    exit 0
fi

# ---------- lts ----------
if [ "$PATCH_LEVEL" = "lts" ]; then
    mb="common-${ANDROID_VERSION}-${KERNEL_VERSION}-lts"
    cb="${ANDROID_VERSION}-${KERNEL_VERSION}-lts"
    has_ref "$MANIFEST_URL" "refs/heads/${mb}" || { echo "错误: manifest 无 $mb" >&2; exit 1; }
    has_ref "$COMMON_URL" "refs/heads/${cb}" || { echo "错误: kernel/common 无 $cb" >&2; exit 1; }
    echo "[detect] 使用 LTS 分支: $cb" >&2
    emit lts "$mb" "$cb" lts 0
    exit 0
fi

# ---------- 指定月份 ----------
if [[ "$PATCH_LEVEL" =~ ^[0-9]{4}-[0-9]{2}$ ]]; then
    mb="common-${ANDROID_VERSION}-${KERNEL_VERSION}-${PATCH_LEVEL}"
    cb="${ANDROID_VERSION}-${KERNEL_VERSION}-${PATCH_LEVEL}"
    has_ref "$MANIFEST_URL" "refs/heads/${mb}" || { echo "错误: manifest 分支不存在: $mb" >&2; exit 1; }
    if has_ref "$COMMON_URL" "refs/heads/${cb}"; then
        dep=0
    elif has_ref "$COMMON_URL" "refs/heads/deprecated/${cb}"; then
        dep=1
    else
        echo "错误: kernel/common 分支不存在: $cb" >&2; exit 1
    fi
    echo "[detect] 使用指定月份: $cb (deprecated=$dep)" >&2
    emit fixed "$mb" "$cb" "$PATCH_LEVEL" "$dep"
    exit 0
fi

[ "$PATCH_LEVEL" = "auto" ] || { echo "错误: 无法识别的 PATCH_LEVEL=$PATCH_LEVEL" >&2; exit 1; }

# ---------- auto: 下个月 + 当月 + 往前 MAX_MONTHS_BACK 个月 ----------
y=$(date -u +%Y)
m=$(date -u +%-m)
m=$((m+1))
if [ "$m" -gt 12 ]; then m=1; y=$((y+1)); fi
cands=()
for ((i=0; i<=MAX_MONTHS_BACK+1; i++)); do
    cands+=("$(printf '%04d-%02d' "$y" "$m")")
    m=$((m-1))
    if [ "$m" -lt 1 ]; then m=12; y=$((y-1)); fi
done

found=""
dep=0
for mon in "${cands[@]}"; do
    mb="common-${ANDROID_VERSION}-${KERNEL_VERSION}-${mon}"
    cb="${ANDROID_VERSION}-${KERNEL_VERSION}-${mon}"
    has_ref "$MANIFEST_URL" "refs/heads/${mb}" || continue
    if has_ref "$COMMON_URL" "refs/heads/${cb}"; then
        dep=0
    elif has_ref "$COMMON_URL" "refs/heads/deprecated/${cb}"; then
        dep=1
    else
        continue
    fi
    found="$mon"
    break
done

if [ -z "$found" ]; then
    echo "错误: 在 $MIRROR 上找不到 $ANDROID_VERSION-$KERNEL_VERSION 有可用匹配的月份分支" >&2
    echo "建议: 换镜像重试 (--mirror google) 或使用 PATCH_LEVEL=tip / lts" >&2
    exit 1
fi

echo "[detect] 检测到最新: ${ANDROID_VERSION}-${KERNEL_VERSION}-${found} (deprecated=$dep)" >&2
emit auto "common-${ANDROID_VERSION}-${KERNEL_VERSION}-${found}" "${ANDROID_VERSION}-${KERNEL_VERSION}-${found}" "$found" "$dep"
