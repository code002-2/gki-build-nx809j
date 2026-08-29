#!/usr/bin/env bash
# =====================================================================
# detect.sh - 自动识别谷歌 android16-6.12 最新的官方发布分支
#
# 输出(供 build.sh eval 使用):
#   DETECT_SOURCE_MODE DETECT_MANIFEST_BRANCH DETECT_COMMON_BRANCH
#   DETECT_MONTH DETECT_DEPRECATED DETECT_SUBLEVEL
#
# 注意: 子版本号(SUBLEVEL)以 repo sync 后的 common/Makefile 为准,
#       这里留空, 避免依赖 gitiles 接口。
# =====================================================================
set -euo pipefail

: "${ANDROID_VERSION:=android16}"
: "${KERNEL_VERSION:=6.12}"
: "${SOURCE_MODE:=release}"
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

# 判断某个 ref 是否存在(ls-remote 无匹配也返回 0, 所以要判断输出非空)
has_ref() { # $1=url $2=ref 模式
    local out
    out=$(git ls-remote --quiet "$1" "$2" 2>/dev/null || true)
    [ -n "$out" ]
}

echo "[detect] 源: $MIRROR  模式: $SOURCE_MODE ($ANDROID_VERSION-$KERNEL_VERSION)" >&2

if [ "$SOURCE_MODE" = "tip" ]; then
    echo "[detect] 使用 android16-6.12 分支头(最新代码)" >&2
    echo "DETECT_SOURCE_MODE=tip"
    echo "DETECT_MANIFEST_BRANCH=common-${ANDROID_VERSION}-${KERNEL_VERSION}"
    echo "DETECT_COMMON_BRANCH=${ANDROID_VERSION}-${KERNEL_VERSION}"
    echo "DETECT_MONTH=tip"
    echo "DETECT_DEPRECATED=0"
    echo "DETECT_SUBLEVEL="
    exit 0
fi

# 候选月份: 下个月(AOSP 会提前切好) + 当月 + 往前 MAX_MONTHS_BACK 个月
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
    # manifest 分支必须存在
    has_ref "$MANIFEST_URL" "refs/heads/${mb}" || continue
    # kernel/common 分支: 优先正式分支, 其次 deprecated
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
    echo "错误: 在 $MIRROR 上找不到 $ANDROID_VERSION-$KERNEL_VERSION 的月度发布分支" >&2
    echo "建议: 换镜像重试 (--mirror google) 或 --source tip" >&2
    exit 1
fi

echo "[detect] 检测到最新发布: ${ANDROID_VERSION}-${KERNEL_VERSION}-${found} (deprecated=$dep)" >&2
echo "DETECT_SOURCE_MODE=$SOURCE_MODE"
echo "DETECT_MANIFEST_BRANCH=common-${ANDROID_VERSION}-${KERNEL_VERSION}-${found}"
echo "DETECT_COMMON_BRANCH=${ANDROID_VERSION}-${KERNEL_VERSION}-${found}"
echo "DETECT_MONTH=$found"
echo "DETECT_DEPRECATED=$dep"
echo "DETECT_SUBLEVEL="
