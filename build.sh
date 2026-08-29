#!/usr/bin/env bash
# =====================================================================
# gki-build-nx809j - 自动构建谷歌最新 android16-6.12 GKI 内核
#   集成 KernelSU(或 ReSukiSU/SukiSU/Next) + SUSFS
#
# 流程参考: github.com/zzh20188/GKI_KernelSU_SUSFS/.github/workflows/build.yml
# 运行环境: Ubuntu(x86_64) - GitHub Actions runner 或 WSL2/本地 Linux
#
# 用法:
#   bash build.sh [--variant Official|ReSukiSU|SukiSU|Next]
#                 [--source release|tip]
#                 [--mirror ustc|google|nju]
#                 [--susfs on|off] [--slim on|off]
#                 [--with-manager on|off] [--clean] [--help]
#
# 产物输出到 work/out/:
#   android16-6.12.<SUBLEVEL>-<月份>-boot.img / -boot-gz.img / -boot-lz4.img
#   android16-6.12.<SUBLEVEL>-<月份>-AnyKernel3.zip
#   INFO.txt
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

[ -f "$SCRIPT_DIR/config.env" ] && . "$SCRIPT_DIR/config.env"

usage() {
    cat <<'EOF'
用法: bash build.sh [选项]
  --variant NAME     KernelSU 变体: Official | ReSukiSU | SukiSU | Next (默认 Official)
  --source MODE      内核源: release=最新月度 GKI 发布(推荐) | tip=android16-6.12 分支头
  --mirror NAME      下载镜像: ustc(中科大) | google(官方) | nju(南大) (默认 ustc)
  --susfs on|off     是否集成 SUSFS (默认 on)
  --slim on|off      精简 sync, 跳过 GBL 相关项目 (默认 on)
  --with-manager on|off  构建后下载管理器 APK (默认 off)
  --clean            清除上一次的 work/ 再构建
  --help             显示本帮助
EOF
}

# ---------------- 参数解析(覆盖 config.env) ----------------
while [ $# -gt 0 ]; do
    case "$1" in
        --variant)      KSU_VARIANT="$2"; shift 2 ;;
        --source)       SOURCE_MODE="$2";  shift 2 ;;
        --mirror)       MIRROR="$2";       shift 2 ;;
        --susfs)        ENABLE_SUSFS="$2"; shift 2 ;;
        --slim)         SLIM="$2";         shift 2 ;;
        --with-manager) WITH_MANAGER="$2"; shift 2 ;;
        --clean)        CLEAN="true";      shift ;;
        --help|-h)      usage; exit 0 ;;
        *) echo "未知参数: $1" >&2; usage; exit 1 ;;
    esac
done

: "${ANDROID_VERSION:=android16}"
: "${KERNEL_VERSION:=6.12}"
: "${KSU_VARIANT:=Official}"
: "${SOURCE_MODE:=release}"
: "${MIRROR:=ustc}"
: "${ENABLE_SUSFS:=true}"
: "${SLIM:=true}"
: "${WITH_MANAGER:=false}"
: "${CLEAN:=false}"
: "${WORK_ROOT:=$SCRIPT_DIR/work}"
: "${OUT_DIR:=$WORK_ROOT/out}"
: "${BUILD_TIME:=}"
: "${JOBS:=}"
: "${MAX_MONTHS_BACK:=9}"

log()  { echo -e "\e[1;32m[build]\e[0m $*"; }
warn() { echo -e "\e[1;33m[build]\e[0m $*"; }
die()  { echo -e "\e[1;31m[build] 错误:\e[0m $*" >&2; exit 1; }

# 布尔归一化
bool() { case "$1" in on|true|1|y|yes) echo true ;; off|false|0|n|no) echo false;; *) die "无法解析布尔值: $1" ;; esac; }
ENABLE_SUSFS="$(bool "$ENABLE_SUSFS")"
SLIM="$(bool "$SLIM")"
WITH_MANAGER="$(bool "$WITH_MANAGER")"

case "$KSU_VARIANT" in Official|ReSukiSU|SukiSU|Next) ;; *) die "未知变体: $KSU_VARIANT" ;; esac

if [ "$CLEAN" = "true" ]; then
    rm -rf "$WORK_ROOT"
fi

# ---------------- 0. 环境检查 ----------------
for c in git curl python3 zip unzip; do
    command -v "$c" >/dev/null || die "缺少命令: $c (请先 apt-get install $c)"
done
log "磁盘可用: $(df -h "$SCRIPT_DIR" | awk 'NR==2{print $4}')"

# ---------------- 1. 自动检测最新内核分支 ----------------
log "检测最新 android16-6.12 分支..."
DETECT_RAW="$(MIRROR="$MIRROR" SOURCE_MODE="$SOURCE_MODE" \
    ANDROID_VERSION="$ANDROID_VERSION" KERNEL_VERSION="$KERNEL_VERSION" \
    MAX_MONTHS_BACK="$MAX_MONTHS_BACK" bash "$SCRIPT_DIR/detect.sh")"
eval "$DETECT_RAW"
COMMON_BRANCH="$DETECT_COMMON_BRANCH"
MANIFEST_BRANCH="$DETECT_MANIFEST_BRANCH"
MONTH="$DETECT_MONTH"
DEPRECATED="$DETECT_DEPRECATED"
log "内核分支: $COMMON_BRANCH   manifest: $MANIFEST_BRANCH"

mirror_base() {
    case "$MIRROR" in
        ustc)   echo "https://mirrors.ustc.edu.cn/aosp" ;;
        nju)    echo "https://mirror.nju.edu.cn/git/aosp" ;;
        google) echo "https://android.googlesource.com" ;;
    esac
}
MANIFEST_URL="$(mirror_base "$MIRROR")/kernel/manifest"

REPO_ROOT="$WORK_ROOT/trees/$COMMON_BRANCH"
REPO_SCRIPT="$WORK_ROOT/git-repo/repo"

# ---------------- 2. 准备 repo 与内核源码 ----------------
if [ ! -x "$REPO_SCRIPT" ]; then
    log "下载 repo 工具..."
    mkdir -p "$(dirname "$REPO_SCRIPT")"
    curl -fL --retry 3 https://storage.googleapis.com/git-repo-downloads/repo -o "$REPO_SCRIPT" ||
        curl -fL https://raw.githubusercontent.com/git-repo/repo/master/repo -o "$REPO_SCRIPT"
    chmod 0755 "$REPO_SCRIPT"
fi

if [ ! -d "$REPO_ROOT/.repo" ]; then
    log "repo init ($MANIFEST_BRANCH)..."
    mkdir -p "$REPO_ROOT"
    (cd "$REPO_ROOT" && "$REPO_SCRIPT" init --depth=1 -u "$MANIFEST_URL" \
        -b "$MANIFEST_BRANCH" --repo-rev=v2.16)
fi

MDEFAULT="$REPO_ROOT/.repo/manifests/default.xml"
[ -f "$MDEFAULT" ] || die "未找到 $MDEFAULT"

# 已弃用分支: manifest 里把 common 指向 deprecated/
if [ "$DEPRECATED" = "1" ] && ! grep -q "deprecated/${COMMON_BRANCH}" "$MDEFAULT"; then
    log "处理 deprecated 分支..."
    sed -i "s/\"${COMMON_BRANCH}\"/\"deprecated\/${COMMON_BRANCH}\"/g" "$MDEFAULT"
fi

# 精简同步: 移除 GBL(引导加载器)相关项目, 编译内核不需要
if [ "$SLIM" = "true" ]; then
    perl -ni -e 'print unless m{<project path="(bootable/|external/arm-trusted-firmware|external/avb|external/boringssl|external/compiler-rt|external/dtc|external/libufdt|external/open-dice|external/elfutils|external/googletest|external/rust/crates/|prebuilts/fuchsia_sdk|prebuilts/jdk/jdk11|test/ltp|system/core)"}' "$MDEFAULT"
    log "slim sync: 已跳过 GBL 相关项目"
fi

log "repo sync (首次约 20-60 分钟)..."
JFLAG=""
[ -n "$JOBS" ] && JFLAG="-j${JOBS}"
(cd "$REPO_ROOT" && "$REPO_SCRIPT" sync -c --no-tags --fail-fast $JFLAG)

# 实际子版本号(以同步后的 Makefile 为准)
COMMON_MAKEFILE="$REPO_ROOT/common/Makefile"
[ -f "$COMMON_MAKEFILE" ] || die "同步后未找到 common/Makefile"
SUBLEVEL="$(grep '^SUBLEVEL = ' "$COMMON_MAKEFILE" | awk '{print $3}')"
[ -n "$SUBLEVEL" ] || die "无法从 Makefile 读取 SUBLEVEL"
KERNEL_COMMIT="$(git -C "$REPO_ROOT/common" rev-parse --short=12 HEAD)"
KERNEL_VERSION_FULL="${KERNEL_VERSION}.${SUBLEVEL}"
log "内核版本: $KERNEL_VERSION_FULL   commit: $KERNEL_COMMIT   (月份: $MONTH)"

# ---------------- 3. 安装构建依赖 ----------------
if [ -n "$(command -v apt-get)" ]; then
    log "安装构建依赖..."
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        ccache python3 python-is-python3 git curl build-essential \
        libssl-dev bison flex libelf-dev dwarves zip unzip 2>/dev/null || true
fi

# ---------------- 4. 集成 KernelSU ----------------
case "$KSU_VARIANT" in
    Official)  KSU_REPO="https://github.com/tiann/KernelSU.git";            KSU_BRANCH="main" ;;
    ReSukiSU)  KSU_REPO="https://github.com/ReSukiSU/ReSukiSU.git";         KSU_BRANCH="main" ;;
    SukiSU)    KSU_REPO="https://github.com/SukiSU-Ultra/SukiSU-Ultra.git"; KSU_BRANCH="builtin" ;;
    Next)      KSU_REPO="https://github.com/KernelSU-Next/KernelSU-Next.git"; KSU_BRANCH="dev_susfs" ;;
esac

if [ ! -d "$REPO_ROOT/KernelSU/.git" ]; then
    log "克隆 KernelSU ($KSU_VARIANT/$KSU_BRANCH)..."
    git clone "$KSU_REPO" "$REPO_ROOT/KernelSU"
    git -C "$REPO_ROOT/KernelSU" checkout -q "$KSU_BRANCH" \
        || warn "切换 $KSU_BRANCH 失败, 使用默认分支"
else
    git -C "$REPO_ROOT/KernelSU" checkout -q "$KSU_BRANCH" 2>/dev/null || true
fi

DRIVER_DIR="$REPO_ROOT/common/drivers"
[ -d "$DRIVER_DIR" ] || die "未找到 $DRIVER_DIR"
ln -sfn "../../KernelSU/kernel" "$DRIVER_DIR/kernelsu"
grep -q "kernelsu" "$DRIVER_DIR/Makefile" \
    || printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$DRIVER_DIR/Makefile"
grep -q 'source "drivers/kernelsu/Kconfig"' "$DRIVER_DIR/Kconfig" \
    || sed -i "/endmenu/i source \"drivers/kernelsu/Kconfig\"" "$DRIVER_DIR/Kconfig"

KSU_VERSION=""
KSU_COMMIT=""
KSU_DATE=""
if [ -d "$REPO_ROOT/KernelSU/.git" ]; then
    KSU_GIT_COUNT="$(git -C "$REPO_ROOT/KernelSU" rev-list --count HEAD || echo 0)"
    KSU_VERSION=$((20000 + KSU_GIT_COUNT))
    KSU_COMMIT="$(git -C "$REPO_ROOT/KernelSU" rev-parse --short=12 HEAD)"
    KSU_DATE="$(git -C "$REPO_ROOT/KernelSU" log -1 --date=format:'%Y-%m-%d %H:%M:%S %z' --format='%cd')"
    if grep -q 'DKSU_VERSION=' "$REPO_ROOT/KernelSU/kernel/Kbuild"; then
        sed -i "s/DKSU_VERSION=16/DKSU_VERSION=${KSU_VERSION}/" "$REPO_ROOT/KernelSU/kernel/Kbuild"
    fi
fi
log "KernelSU: $KSU_VARIANT  version=$KSU_VERSION  commit=$KSU_COMMIT  ($KSU_DATE)"

# ---------------- 5. 集成 SUSFS ----------------
apply_susfs() {
    log "集成 SUSFS (gki-${ANDROID_VERSION}-${KERNEL_VERSION})..."
    local SUSFS4KSU="$WORK_ROOT/susfs4ksu"
    local SUSFS_BRANCH="gki-${ANDROID_VERSION}-${KERNEL_VERSION}"

    if [ ! -d "$SUSFS4KSU/.git" ]; then
        if ! git clone -b "$SUSFS_BRANCH" https://gitlab.com/simonpunk/susfs4ksu.git "$SUSFS4KSU.tmp" 2>/dev/null; then
            rm -rf "$SUSFS4KSU.tmp"
            git clone -b "$SUSFS_BRANCH" https://github.com/ShirkNeko/susfs4ksu.git "$SUSFS4KSU.tmp" \
                || die "无法克隆 susfs4ksu (分支 $SUSFS_BRANCH)"
        fi
        mv "$SUSFS4KSU.tmp" "$SUSFS4KSU"
    else
        git -C "$SUSFS4KSU" checkout -q "$SUSFS_BRANCH" 2>/dev/null || true
    fi

    local SUSFS_PATCH="50_add_susfs_in_gki-${ANDROID_VERSION}-${KERNEL_VERSION}.patch"
    [ -f "$SUSFS4KSU/kernel_patches/$SUSFS_PATCH" ] || die "susfs4ksu 缺少补丁: $SUSFS_PATCH"

    cp "$SUSFS4KSU/kernel_patches/$SUSFS_PATCH" "$REPO_ROOT/common/"
    cp "$SUSFS4KSU/kernel_patches/fs/"*          "$REPO_ROOT/common/fs/"
    cp "$SUSFS4KSU/kernel_patches/include/linux/"* "$REPO_ROOT/common/include/linux/"

    # 官方 KernelSU 需要额外补丁启用 SUSFS
    if [ "$KSU_VARIANT" = "Official" ]; then
        (cd "$REPO_ROOT/KernelSU" && cp "$SUSFS4KSU/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch" ./
         if grep -q '^diff --git a/kernel/Makefile b/kernel/Makefile' ./10_enable_susfs_for_ksu.patch \
             && ! grep -q '^diff --git a/kernel/Kbuild b/kernel/Kbuild' ./10_enable_susfs_for_ksu.patch; then
             sed -i 's|kernel/Makefile|kernel/Kbuild|g' ./10_enable_susfs_for_ksu.patch
         fi
         patch -p1 --forward < 10_enable_susfs_for_ksu.patch || true)
    fi

    # ---------- 参考 zzh 的 susfs_fixes/apply.sh: android16-6.12 ----------
    local SUB="$SUBLEVEL"
    (cd "$REPO_ROOT/common"
     # 6.12.58+: exec.c 头部上下文变化, 先移除 dma-buf.h 再打补丁, 之后还原
     if [ "$SUB" -ge 58 ] 2>/dev/null; then
         sed -i '/^#include <linux\/dma-buf.h>$/d' fs/exec.c
     fi

     patch -p1 < "$SUSFS_PATCH" || true

     # 还原 exec.c
     if [ "$SUB" -ge 58 ] 2>/dev/null && ! grep -qF '#include <linux/dma-buf.h>' fs/exec.c; then
         sed -i '0,/^#include /s//#include <linux\/dma-buf.h>\n&/' fs/exec.c
     fi

     # setuid_hook.c 重复定义修复
     local SETUID_HOOK="$REPO_ROOT/common/drivers/kernelsu/setuid_hook.c"
     if [ -f "$SETUID_HOOK" ]; then
         sed -i 's/defined(CONFIG_KSU_MANUAL_HOOK))/!defined(CONFIG_KSU_SUSFS) \&\& defined(CONFIG_KSU_MANUAL_HOOK))/' "$SETUID_HOOK"
     fi

     # exec.c 漏掉 susfs_def.h 修复
     if grep -q 'susfs_is_current_proc_umounted' fs/exec.c && ! grep -qF '#include <linux/susfs_def.h>' fs/exec.c; then
         if grep -qF '#include <linux/dma-buf.h>' fs/exec.c; then
             sed -i '/#include <linux\/dma-buf.h>/a #ifdef CONFIG_KSU_SUSFS\n#include <linux\/susfs_def.h>\n#endif' fs/exec.c
         else
             sed -i '/#include <linux\/ksm.h>/a #ifdef CONFIG_KSU_SUSFS\n#include <linux\/susfs_def.h>\n#endif' fs/exec.c
         fi
     fi
    )

    local REJ_COUNT
    REJ_COUNT="$(find "$REPO_ROOT/common" -name '*.rej' | wc -l)"
    if [ "$REJ_COUNT" -gt 0 ]; then
        warn "SUSFS 补丁产生 $REJ_COUNT 个 .rej 冲突, 可能导致编译失败:"
        find "$REPO_ROOT/common" -name '*.rej' | sed 's/^/    /'
    fi

    SUSFS_COMMIT="$(git -C "$SUSFS4KSU" rev-parse --short=12 HEAD)"
    SUSFS_DATE="$(git -C "$SUSFS4KSU" log -1 --date=format:'%Y-%m-%d %H:%M:%S %z' --format='%cd')"
    log "SUSFS: commit=$SUSFS_COMMIT ($SUSFS_DATE)"
}

if [ "$ENABLE_SUSFS" = "true" ]; then
    apply_susfs
else
    SUSFS_COMMIT=""
    SUSFS_DATE=""
    warn "SUSFS 已禁用"
fi

# ---------------- 6. 内核配置 ----------------
DEFCONFIG_ORIG="$REPO_ROOT/common/arch/arm64/configs/gki_defconfig"
[ -f "$DEFCONFIG_ORIG" ] || die "未找到 gki_defconfig"

# 备份基准(后面 diff 成 fragment 用)
BASELINE="$WORK_ROOT/defconfig.orig"
cp "$DEFCONFIG_ORIG" "$BASELINE"

log "追加内核配置..."
cat >> "$DEFCONFIG_ORIG" <<'EOF'
CONFIG_KSU=y
CONFIG_TMPFS_XATTR=y
CONFIG_TMPFS_POSIX_ACL=y
EOF

if [ "$ENABLE_SUSFS" = "true" ]; then
    cat >> "$DEFCONFIG_ORIG" <<'EOF'
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
EOF
fi

# 内核名称: KMI 后缀 + 去掉 dirty
log "设置内核版本名..."
BID="ab$((RANDOM % 90000000 + 10000000))"
GHASH="$(git -C "$REPO_ROOT/common" rev-parse --verify HEAD | cut -c1-13)"
KMI_TAG="android16-5"
KMI_SUFFIX="-${KMI_TAG}-g${GHASH}-${BID}"

(
    cd "$REPO_ROOT"
    # 去掉 -dirty (若使用 build.sh 路径)
    [ -f "build/build.sh" ] && sed -i 's/-dirty//' ./common/scripts/setlocalversion || true
    # bazel 路径: 去掉 KMI 严格检查
    sed -i '/^[[:space:]]*"protected_exports_list"[[:space:]]*:[[:space:]]*"android\/abi_gki_protected_exports_aarch64",$/d' ./common/BUILD.bazel
    sed -i '/kmi_symbol_list_strict_mode/d' ./common/BUILD.bazel
    rm -rf ./common/android/abi_gki_protected_exports_*
    sed -i "/stable_scmversion_cmd/s/-maybe-dirty//g" ./build/kernel/kleaf/impl/stamp.bzl || true
    # KMI 后缀注入 uname -r
    cd ./common
    perl -i -0777 -pe 's/(.*)echo "\$\{KERNELVERSION\}\$\{file_localversion\}\$\{config_localversion\}\$\{LOCALVERSION\}\$\{scm_version\}"/$1echo "\$\{KERNELVERSION}'"${KMI_SUFFIX}"'\$\{config_localversion\}"/s' ./scripts/setlocalversion 2>/dev/null || true
)

# 自定义构建时间 / 伪装 UTS_VERSION
if [ -n "$BUILD_TIME" ]; then
    DATESTR="$BUILD_TIME"
else
    DATESTR="$(TZ=UTC date +'%a %b %d %T %Z %Y')"
fi
export KBUILD_BUILD_TIMESTAMP="$DATESTR"
export KBUILD_BUILD_VERSION=1
MKCOMPILE_H="$REPO_ROOT/common/scripts/mkcompile_h"
if [ -f "$MKCOMPILE_H" ]; then
    perl -pi -e "s{UTS_VERSION=\"\\\$\\\(.*?\\\)\"}{UTS_VERSION=\"#1 SMP PREEMPT $DATESTR\"}" "$MKCOMPILE_H"
fi
log "构建时间戳: $DATESTR"

# ---------------- 7. 编译 ----------------
log "开始编译 (bazel/kleaf, 首次约 30-90 分钟)..."
(
    cd "$REPO_ROOT"
    sed -i 's/BUILD_SYSTEM_DLKM=1/BUILD_SYSTEM_DLKM=0/' ./common/build.config.gki.aarch64 || true
    sed -i '/MODULES_ORDER=android\/gki_aarch64_modules/d' ./common/build.config.gki.aarch64 || true
    sed -i '/KMI_SYMBOL_LIST_STRICT_MODE/d' ./common/build.config.gki.aarch64 || true

    if [ -f "build/build.sh" ]; then
        # 旧 build.sh 路径(6.12 一般不会走到这里)
        LTO=thin BUILD_CONFIG=common/build.config.gki.aarch64 build/build.sh CC="/usr/bin/ccache clang"
    else
        # 把对 defconfig 的修改 diff 成 fragment, 避免 bazel trim 检查失败
        FRAG="common/arch/arm64/configs/ksu.fragment"
        diff "$BASELINE" "$DEFCONFIG_ORIG" | grep '^>' | sed 's/^> //; s/^[[:space:]]*//' > "$FRAG" || true
        cp "$BASELINE" "$DEFCONFIG_ORIG"
        echo "=== ksu.fragment ==="
        cat "$FRAG"
        echo "====================="

        FRAG_FLAG=""
        [ -s "$FRAG" ] && FRAG_FLAG="--defconfig_fragment=//common:arch/arm64/configs/ksu.fragment"
        mkdir -p "$WORK_ROOT/bazel-cache"
        tools/bazel build --disk_cache="$WORK_ROOT/bazel-cache" --config=fast --lto=none $FRAG_FLAG \
            //common:kernel_aarch64_dist
        strings ./bazel-bin/common/kernel_aarch64/Image 2>/dev/null | grep -m1 'Linux version' || true
    fi
)

# ---------------- 8. 打包 ----------------
log "打包产物..."
mkdir -p "$OUT_DIR"
SRC_IMG="$REPO_ROOT/bazel-bin/common/kernel_aarch64"
[ -f "$SRC_IMG/Image" ] || die "未找到编译产物 Image ($SRC_IMG)"
cp "$SRC_IMG/Image" "$OUT_DIR/Image"
[ -f "$SRC_IMG/Image.lz4" ] && cp "$SRC_IMG/Image.lz4" "$OUT_DIR/Image.lz4" || warn "无 Image.lz4"
gzip -n -k -f -9 "$OUT_DIR/Image"

# AnyKernel3 刷入包
ANYKERNEL3="$WORK_ROOT/AnyKernel3"
if [ ! -d "$ANYKERNEL3" ]; then
    git clone -b gki-2.0 https://github.com/WildKernels/AnyKernel3.git "$ANYKERNEL3"
fi
rm -rf "$ANYKERNEL3/.git"
cd "$ANYKERNEL3"
rm -f Image
cp "$OUT_DIR/Image" ./Image
zip -r -q "$OUT_DIR/${ANDROID_VERSION}-${KERNEL_VERSION}.${SUBLEVEL}-${MONTH}-AnyKernel3.zip" ./*
cd "$SCRIPT_DIR"

# Boot 镜像 (header v4)
MKBOOTIMG="$REPO_ROOT/tools/mkbootimg/mkbootimg.py"
AVBTOOL="$REPO_ROOT/prebuilts/kernel-build-tools/linux-x86/bin/avbtool"
TESTKEY="$REPO_ROOT/prebuilts/kernel-build-tools/linux-x86/share/avb/testkey_rsa2048.pem"
[ -f "$MKBOOTIMG" ] || die "未找到 mkbootimg.py"
[ -x "$AVBTOOL" ] || die "未找到 avbtool"
if [ ! -f "$TESTKEY" ]; then
    warn "无系统 testkey, 生成临时签名密钥"
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 > "$WORK_ROOT/avb-testkey.pem" 2>/dev/null || true
    TESTKEY="$WORK_ROOT/avb-testkey.pem"
fi

make_boot() { # $1=内核文件 $2=输出名
    python3 "$MKBOOTIMG" --header_version 4 --kernel "$1" --output "$OUT_DIR/$2"
    "$AVBTOOL" add_hash_footer --partition_name boot --partition_size $((64 * 1024 * 1024)) \
        --image "$OUT_DIR/$2" --algorithm SHA256_RSA2048 --key "$TESTKEY"
}

BASE="${ANDROID_VERSION}-${KERNEL_VERSION}.${SUBLEVEL}-${MONTH}"
make_boot "$OUT_DIR/Image"      "${BASE}-boot.img"
make_boot "$OUT_DIR/Image.gz"   "${BASE}-boot-gz.img"
if [ -f "$OUT_DIR/Image.lz4" ]; then
    make_boot "$OUT_DIR/Image.lz4" "${BASE}-boot-lz4.img"
fi

# 管理器 APK(可选)
if [ "$WITH_MANAGER" = "true" ]; then
    log "下载 KernelSU 管理器..."
    case "$KSU_VARIANT" in
        Official) MGR_REPO="tiann/KernelSU" ;;
        ReSukiSU) MGR_REPO="ReSukiSU/ReSukiSU" ;;
        SukiSU)   MGR_REPO="SukiSU-Ultra/SukiSU-Ultra" ;;
        Next)     MGR_REPO="KernelSU-Next/KernelSU-Next" ;;
    esac
    MGR_URL="$(curl -fsSL "https://api.github.com/repos/${MGR_REPO}/releases/latest" \
        | grep -o 'https://[^"]*\.apk' | head -n1 || true)"
    if [ -n "$MGR_URL" ]; then
        curl -fL "$MGR_URL" -o "$OUT_DIR/ksu-manager.apk" || warn "管理器下载失败"
    else
        warn "未找到管理器 APK 下载地址"
    fi
fi

# INFO
{
    echo "== GKI KernelSU+SUSFS 构建信息 =="
    echo "设备目标      : NX809J (红魔 11 系列, Android 16 内核)"
    echo "内核版本      : $KERNEL_VERSION_FULL"
    echo "内核分支      : $COMMON_BRANCH"
    echo "内核 commit   : $KERNEL_COMMIT"
    echo "构建时间戳    : $DATESTR"
    echo "KernelSU 变体 : $KSU_VARIANT (v$KSU_VERSION, commit $KSU_COMMIT, $KSU_DATE)"
    echo "SUSFS         : $ENABLE_SUSFS (commit $SUSFS_COMMIT, $SUSFS_DATE)"
    echo "镜像源        : $MIRROR"
} > "$OUT_DIR/INFO.txt"

log "构建完成!"
echo ""
echo "===================== 产物 ($OUT_DIR) ====================="
ls -lh "$OUT_DIR"
echo "============================================================"
