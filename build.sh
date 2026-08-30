#!/usr/bin/env bash
# =====================================================================
# gki-build-nx809j - 自动构建谷歌最新 android16-6.12 GKI 内核(固定 6.12)
#   集成 KernelSU(ReSukiSU/SukiSU/Next) + SUSFS + 全套可选功能
#
# 功能与开关对齐 github.com/zzh20188/GKI_KernelSU_SUSFS/.github/workflows/build.yml
#   安全补丁级别(auto/tip/lts/指定月份)  KernelSU 变体  自定义版本名
#   自定义构建时间  KPM  Droidspaces(+NTSync)  产物上传模式  ZRAM(v6.12跳过)
#   BBG  Re-Kernel  CVE-2026-43499 修复链  禁用 SUSFS  一加 8E 支持
#
# 运行环境: Ubuntu x86_64 (GitHub Actions runner / WSL2 / 本地 Linux)
# 用法: bash build.sh [选项...] ; 亦可全部用环境变量(config.env 可编辑)
# 产物: work/out/
# =====================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

[ -f "$SCRIPT_DIR/config.env" ] && . "$SCRIPT_DIR/config.env"

usage() {
    sed -n '3,18p' "$0" | sed 's/^..//'
    cat <<'EOF'
选项(不传则用 config.env / 环境变量):
  --patch-level X   auto | tip | lts | 2026-09 等月份 (默认 auto)
  --variant NAME    Official | ReSukiSU | SukiSU | Next (默认 Official)
  --mirror NAME     ustc | google | nju (默认 ustc)
  --susfs on|off    是否集成 SUSFS (默认 on)
  --kpm MODE        disabled | enabled | patched (默认 disabled)
  --droidspaces X   off | on (默认 off)
  --ntsync on|off   Droidspaces NTSync 支持 (默认 off)
  --artifact-mode M all | anykernel3 (默认 all)
  --zram on|off     ZRAM 增强 (6.12 上游未适配, 会提示并跳过)
  --bbg on|off      BBG 防格机 (默认 off)
  --re-kernel on|off  Re-Kernel 驱动 (默认 off)
  --cve on|off      应用 CVE-2026-43499/53163 修复链 (默认 off)
  --oneplus on|off  一加 8E 支持 (默认 off)
  --version-name S  自定义版本名
  --build-time S    自定义构建时间, "Sun Dec 01 08:10:00 UTC 2024"
  --with-manager on|off  下载管理器 APK (默认 off)
  --slim on|off     精简 sync (默认 on)
  --clean           清理 work/ 后构建
  --help            显示本帮助
EOF
}

# ---------------- 参数解析 ----------------
while [ $# -gt 0 ]; do
    case "$1" in
        --patch-level)  PATCH_LEVEL="$2";        shift 2 ;;
        --source)       PATCH_LEVEL="$2";        shift 2 ;;   # 兼容旧参数
        --variant)      KSU_VARIANT="$2";        shift 2 ;;
        --mirror)       MIRROR="$2";             shift 2 ;;
        --susfs)        ENABLE_SUSFS="$2";       shift 2 ;;
        --kpm)          USE_KPM="$2";            shift 2 ;;
        --droidspaces)  DROIDSPACES="$2";        shift 2 ;;
        --ntsync)       DROIDSPACES_NTSYNC="$2"; shift 2 ;;
        --artifact-mode) ARTIFACT_MODE="$2";     shift 2 ;;
        --zram)         USE_ZRAM="$2";           shift 2 ;;
        --bbg)          USE_BBG="$2";            shift 2 ;;
        --re-kernel)    USE_REKERNEL="$2";       shift 2 ;;
        --cve)          CVE_2026_43499_PATCH="$2"; shift 2 ;;
        --oneplus)      SUPP_OP="$2";            shift 2 ;;
        --version-name) VERSION_NAME="$2";       shift 2 ;;
        --build-time)   BUILD_TIME="$2";         shift 2 ;;
        --with-manager) WITH_MANAGER="$2";       shift 2 ;;
        --slim)         SLIM="$2";               shift 2 ;;
        --clean)        CLEAN="true";            shift ;;
        --help|-h)      usage; exit 0 ;;
        *) echo "未知参数: $1" >&2; usage; exit 1 ;;
    esac
done

# ---------------- 默认值与归一化 ----------------
: "${ANDROID_VERSION:=android16}"
: "${KERNEL_VERSION:=6.12}"
: "${PATCH_LEVEL:=auto}"
: "${KSU_VARIANT:=Official}"
: "${MIRROR:=ustc}"
: "${ENABLE_SUSFS:=true}"
: "${USE_KPM:=disabled}"
: "${DROIDSPACES:=off}"
: "${DROIDSPACES_NTSYNC:=false}"
: "${ARTIFACT_MODE:=all}"
: "${USE_ZRAM:=false}"
: "${USE_BBG:=false}"
: "${USE_REKERNEL:=false}"
: "${CVE_2026_43499_PATCH:=false}"
: "${CANCEL_SUSFS:=false}"
: "${SUPP_OP:=false}"
: "${VERSION_NAME:=}"
: "${BUILD_TIME:=}"
: "${WITH_MANAGER:=false}"
: "${SLIM:=true}"
: "${CLEAN:=false}"
: "${WORK_ROOT:=$SCRIPT_DIR/work}"
: "${OUT_DIR:=$WORK_ROOT/out}"
: "${JOBS:=}"
: "${MAX_MONTHS_BACK:=9}"

log()  { echo -e "\e[1;32m[build]\e[0m $*"; }
warn() { echo -e "\e[1;33m[build]\e[0m $*"; }
die()  { echo -e "\e[1;31m[build] 错误:\e[0m $*" >&2; exit 1; }
bool() { case "$1" in on|true|1|y|yes) echo true ;; off|false|0|n|no) echo false;; *) die "无法解析布尔值: $1" ;; esac; }

for v in ENABLE_SUSFS DROIDSPACES_NTSYNC USE_ZRAM USE_BBG USE_REKERNEL CVE_2026_43499_PATCH SUPP_OP WITH_MANAGER SLIM; do
    eval "$v=\"\$(bool \"\${$v}\")\""
done
if [ "$(bool "$CANCEL_SUSFS")" = "true" ]; then ENABLE_SUSFS="false"; fi

case "$KSU_VARIANT" in Official|ReSukiSU|SukiSU|Next|None) ;; *) die "未知 KSU_VARIANT: $KSU_VARIANT" ;; esac
# None = 纯内核, 不集成 KernelSU, 因此 SUSFS/KPM/管理器全部关闭
if [ "$KSU_VARIANT" = "None" ]; then
    warn "KSU 变体为 None: 不集成 KernelSU / SUSFS / KPM / 管理器 (纯内核构建)"
    ENABLE_SUSFS="false"
    USE_KPM="disabled"
    WITH_MANAGER="false"
fi
case "$USE_KPM" in disabled|enabled|patched) ;; *) die "USE_KPM 只能是 disabled/enabled/patched" ;; esac
case "$ARTIFACT_MODE" in all|anykernel3) ;; *) die "ARTIFACT_MODE 只能是 all/anykernel3" ;; esac
# 兼容 true/false(部分前端会把 on/off 序列化成布尔)
case "$DROIDSPACES" in
    on|true|yes|1)  DROIDSPACES="on" ;;
    off|false|no|0) DROIDSPACES="off" ;;
    *) die "DROIDSPACES 只能是 on/off: $DROIDSPACES" ;;
esac
if [ "$DROIDSPACES_NTSYNC" = "true" ] && [ "$DROIDSPACES" != "on" ]; then
    warn "NTSync 需要 Droidspaces 开启, 已自动忽略 NTSync"
    DROIDSPACES_NTSYNC="false"
fi
if [ "$USE_ZRAM" = "true" ]; then
    warn "ZRAM 增强在 6.12 上上游未适配(zzh 同款矩阵在 6.12 也是关闭的), 自动跳过"
    USE_ZRAM="false"
fi

if [ "$CLEAN" = "true" ]; then
    rm -rf "$WORK_ROOT"
fi

log "===== 构建配置 ====="
log "内核: $ANDROID_VERSION-$KERNEL_VERSION  补丁级别: $PATCH_LEVEL  变体: $KSU_VARIANT"
log "SUSFS=$ENABLE_SUSFS KPM=$USE_KPM Droidspaces=$DROIDSPACES(ntsync=$DROIDSPACES_NTSYNC) 产物模式=$ARTIFACT_MODE"
log "ZRAM=$USE_ZRAM BBG=$USE_BBG Re-Kernel=$USE_REKERNEL CVE=$CVE_2026_43499_PATCH 一加8E=$SUPP_OP"

# ---------------- 0. 环境检查 ----------------
for c in git curl python3 zip unzip; do
    command -v "$c" >/dev/null || die "缺少命令: $c (请先 apt-get install $c)"
done
log "磁盘可用: $(df -h "$SCRIPT_DIR" | awk 'NR==2{print $4}')"

# ---------------- 1. 自动检测分支 ----------------
log "检测内核分支..."
DETECT_RAW="$(MIRROR="$MIRROR" PATCH_LEVEL="$PATCH_LEVEL" \
    ANDROID_VERSION="$ANDROID_VERSION" KERNEL_VERSION="$KERNEL_VERSION" \
    MAX_MONTHS_BACK="$MAX_MONTHS_BACK" bash "$SCRIPT_DIR/detect.sh")"
eval "$DETECT_RAW"
COMMON_BRANCH="$DETECT_COMMON_BRANCH"
MANIFEST_BRANCH="$DETECT_MANIFEST_BRANCH"
MONTH="$DETECT_MONTH"
DEPRECATED="$DETECT_DEPRECATED"
OS_PATCH_LEVEL="$MONTH"
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

# ---------------- 2. repo 初始化与同步 ----------------
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

if [ "$DEPRECATED" = "1" ] && ! grep -q "deprecated/${COMMON_BRANCH}" "$MDEFAULT"; then
    log "处理 deprecated 分支..."
    sed -i "s/\"${COMMON_BRANCH}\"/\"deprecated\/${COMMON_BRANCH}\"/g" "$MDEFAULT"
fi

if [ "$SLIM" = "true" ]; then
    # 用 python3 改写 manifest (repo sync 会刷新 manifest, 不能依赖 sed -i 之外的 perl)
    python3 - "$MDEFAULT" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    content = f.read()
removed = [
    "bootable/",
    "external/arm-trusted-firmware",
    "external/avb",
    "external/boringssl",
    "external/compiler-rt",
    "external/dtc",
    "external/libufdt",
    "external/open-dice",
    "external/elfutils",
    "external/googletest",
    "external/rust/crates/",
    "prebuilts/fuchsia_sdk",
    "prebuilts/jdk/jdk11",
    "test/ltp",
    "system/core",
]
pat = re.compile(r'<project path="(%s)"' % "|".join(re.escape(r) for r in removed))
lines = content.splitlines(keepends=True)
kept = [l for l in lines if not pat.search(l)]
with open(path, "w", encoding="utf-8") as f:
    f.writelines(kept)
print(f"removed {len(lines)-len(kept)} project lines (slim)")
PYEOF
    log "slim sync: 已跳过 GBL 相关项目"
    # 提交到 manifest 仓库, 防止 repo sync 刷新 manifest 时覆盖修改
    git -C "$REPO_ROOT/.repo/manifests" add -A 2>/dev/null || true
    git -C "$REPO_ROOT/.repo/manifests" commit -m "slim: drop GBL-related projects" 2>/dev/null || true
fi

log "repo sync (首次约 20-60 分钟)..."
JFLAG=""
[ -n "$JOBS" ] && JFLAG="-j${JOBS}"
(cd "$REPO_ROOT" && "$REPO_SCRIPT" sync -c --no-tags --fail-fast $JFLAG)

COMMON_MAKEFILE="$REPO_ROOT/common/Makefile"
if [ ! -f "$COMMON_MAKEFILE" ]; then
    warn "repo sync 后未找到 common/Makefile, 先执行 repo sync common 项目..."
    (cd "$REPO_ROOT" && "$REPO_SCRIPT" sync -c --no-tags common) || true
fi
if [ ! -f "$COMMON_MAKEFILE" ]; then
    warn "repo sync common 仍未生效, 输出诊断:"
    ls -la "$REPO_ROOT/common" 2>&1 | head -n 10 || true
    grep -n 'path="common"' "$MDEFAULT" 2>&1 || true
    log "兜底: 浅克隆 kernel/common ($COMMON_BRANCH) [镜像链 google->ustc->nju]..."
    CLONE_OK=false
    for CMIRROR in "$MIRROR" ustc nju; do
        CURL="$(case "$CMIRROR" in
            ustc)   echo "https://mirrors.ustc.edu.cn/aosp" ;;
            nju)    echo "https://mirror.nju.edu.cn/git/aosp" ;;
            google) echo "https://android.googlesource.com" ;;
        esac)/kernel/common"
        warn "尝试 $CURL ..."
        rm -rf "$REPO_ROOT/common.tmp"
        if git clone --depth 1 --single-branch -b "$COMMON_BRANCH" "$CURL" "$REPO_ROOT/common.tmp" 2>&1 | tail -n 3 \
            && [ -f "$REPO_ROOT/common.tmp/Makefile" ]; then
            CLONE_OK=true
            break
        fi
    done
    if [ "$CLONE_OK" = "true" ]; then
        rm -rf "$REPO_ROOT/common"
        mv "$REPO_ROOT/common.tmp" "$REPO_ROOT/common"
        warn "已用镜像兜底克隆 common 成功"
    else
        die "兜底克隆 kernel/common 失败"
    fi
fi
[ -f "$COMMON_MAKEFILE" ] || die "同步后仍未找到 common/Makefile"
SUBLEVEL="$(grep '^SUBLEVEL = ' "$COMMON_MAKEFILE" | awk '{print $3}')"
[ -n "$SUBLEVEL" ] || die "无法从 Makefile 读取 SUBLEVEL"
KERNEL_COMMIT="$(git -C "$REPO_ROOT/common" rev-parse --short=12 HEAD)"
KERNEL_VERSION_FULL="${KERNEL_VERSION}.${SUBLEVEL}"
log "内核版本: $KERNEL_VERSION_FULL   commit: $KERNEL_COMMIT   (补丁级别: $OS_PATCH_LEVEL)"

# defconfig 基准备份(后续所有 defconfig 修改最终 diff 成 fragment)
DEFCONFIG="$REPO_ROOT/common/arch/arm64/configs/gki_defconfig"
[ -f "$DEFCONFIG" ] || die "未找到 gki_defconfig"
BASELINE="$WORK_ROOT/defconfig.orig"
cp "$DEFCONFIG" "$BASELINE"

# ---------------- 3. CVE-2026-43499/53163 修复链 ----------------
if [ "$CVE_2026_43499_PATCH" = "true" ]; then
    log "应用 CVE-2026-43499/53163 rtmutex 修复链..."
    (cd "$REPO_ROOT/common" && bash "$SCRIPT_DIR/security_patch/apply_cve_2026_43499.sh" \
        "$KERNEL_VERSION" "$SUBLEVEL" "$SCRIPT_DIR/security_patch")
fi

# ---------------- 4. 一加 8E 支持 ----------------
if [ "$SUPP_OP" = "true" ]; then
    log "添加一加 8E 处理器支持..."
    curl -fLSs "https://github.com/zzh20188/GKI_KernelSU_SUSFS/raw/refs/heads/dev/hmbird_patch.c" \
        -o "$REPO_ROOT/common/drivers/hmbird_patch.c"
    echo "obj-y += hmbird_patch.o" >> "$REPO_ROOT/common/drivers/Makefile"
fi

# ---------------- 5. 集成 KernelSU (None = 纯内核, 跳过) ----------------
# 统一初始化, 避免 None 模式下引用未绑定变量
KSU_VERSION=""
KSU_COMMIT=""
KSU_DATE=""
if [ "$KSU_VARIANT" != "None" ]; then
case "$KSU_VARIANT" in
    Official)  KSU_REPO="https://github.com/tiann/KernelSU.git";            KSU_BRANCH="main" ;;
    ReSukiSU)  KSU_REPO="https://github.com/ReSukiSU/ReSukiSU.git";         KSU_BRANCH="main" ;;
    SukiSU)    KSU_REPO="https://github.com/SukiSU-Ultra/SukiSU-Ultra.git"; KSU_BRANCH="builtin" ;;
    Next)      KSU_REPO="https://github.com/KernelSU-Next/KernelSU-Next.git"; KSU_BRANCH="dev_susfs" ;;
esac
# 与上游一致: SukiSU 关闭 SUSFS 时用 main 分支
[ "$KSU_VARIANT" = "SukiSU" ] && [ "$ENABLE_SUSFS" = "false" ] && KSU_BRANCH="main"

if [ ! -d "$REPO_ROOT/KernelSU/.git" ]; then
    log "克隆 KernelSU ($KSU_VARIANT @ $KSU_BRANCH)..."
    git clone "$KSU_REPO" "$REPO_ROOT/KernelSU"
    git -C "$REPO_ROOT/KernelSU" checkout -q "$KSU_BRANCH" \
        || warn "切换 $KSU_BRANCH 失败, 使用默认分支"
else
    git -C "$REPO_ROOT/KernelSU" checkout -q "$KSU_BRANCH" 2>/dev/null || true
fi

DRIVER_DIR="$REPO_ROOT/common/drivers"
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
log "KernelSU: $KSU_VARIANT  v$KSU_VERSION  $KSU_COMMIT  ($KSU_DATE)"
fi # KSU_VARIANT != None

# ---------------- 6. SUSFS(使用 vendored 的 susfs_fixes/apply.sh, 与上游逐字一致) ----------------
SUSFS4KSU="$WORK_ROOT/susfs4ksu"
SUSFS_BRANCH="gki-${ANDROID_VERSION}-${KERNEL_VERSION}"
SUSFS_COMMIT=""
SUSFS_DATE=""
if [ "$ENABLE_SUSFS" = "true" ]; then
    log "克隆 SUSFS ($SUSFS_BRANCH)..."
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

    log "应用 SUSFS 补丁(含 6.12 上下文修复)..."
    (
        cd "$REPO_ROOT"
        ANDROID_VERSION="$ANDROID_VERSION" KERNEL_VERSION="$KERNEL_VERSION" \
        KSU_VARIANT="$KSU_VARIANT" OS_PATCH_LEVEL="$OS_PATCH_LEVEL" SUB_LEVEL="$SUBLEVEL" \
        KERNEL_ROOT="$REPO_ROOT" SUSFS4KSU="$SUSFS4KSU" KERNEL_PATCHES="" LEGACY_SUKISU_CONFIG="" \
        bash "$SCRIPT_DIR/scripts/susfs_fixes/apply.sh"
    )
    SUSFS_COMMIT="$(git -C "$SUSFS4KSU" rev-parse --short=12 HEAD)"
    SUSFS_DATE="$(git -C "$SUSFS4KSU" log -1 --date=format:'%Y-%m-%d %H:%M:%S %z' --format='%cd')"
    log "SUSFS: $SUSFS_COMMIT ($SUSFS_DATE)"

    # Unicode 绕过修复(与上游一致)
    log "应用 Unicode 绕过修复..."
    ACTION_BUILD="$WORK_ROOT/Action-Build"
    [ -d "$ACTION_BUILD/.git" ] || git clone --depth 1 https://github.com/Numbersf/Action-Build.git "$ACTION_BUILD"
    if [ "$KERNEL_VERSION" = "5.10" ] || [ "$KERNEL_VERSION" = "5.15" ]; then
        patch -p1 --forward < "$ACTION_BUILD/patches/unicode_bypass_fix_6.1-.patch" || true
    else
        patch -p1 --forward < "$ACTION_BUILD/patches/unicode_bypass_fix_6.1+.patch" || true
    fi
fi

# ---------------- 7. Droidspaces 容器支持 ----------------
if [ "$DROIDSPACES" != "off" ]; then
    log "集成 Droidspaces 容器支持..."
    DROIDSPACES_OSS="$WORK_ROOT/Droidspaces-OSS"
    [ -d "$DROIDSPACES_OSS/.git" ] || git clone --depth 1 https://github.com/ravindu644/Droidspaces-OSS.git "$DROIDSPACES_OSS"
    DROIDSPACES_PATCHES="$DROIDSPACES_OSS/Documentation/resources/kernel-patches/GKI"

    (
        cd "$REPO_ROOT/common"
        case "$KERNEL_VERSION" in
            6.12)
                PATCH_FILE="$DROIDSPACES_PATCHES/kernel-6.12/001.GKI-6.12-or-above-fix_sysvipc_kabi.patch"
                ;;
            *)
                PATCH_FILE="$DROIDSPACES_PATCHES/below-kernel-6.12/001.GKI-below-6.12-fix_sysvipc_kabi_678.patch"
                ;;
        esac
        if ! patch -p1 --forward < "$PATCH_FILE"; then
            warn "SYSVIPC kABI 补丁应用失败, 可能已应用或上下文不匹配"
        fi

        # 6.12: rust_binder 需要补符号导出
        if [ "$KERNEL_VERSION" = "6.12" ]; then
            if [ -f "ipc/msgutil.c" ] && ! grep -qF 'EXPORT_SYMBOL(init_ipc_ns);' "ipc/msgutil.c"; then
                sed -i '/^struct msg_msgseg {/i EXPORT_SYMBOL(init_ipc_ns);' "ipc/msgutil.c"
            fi
            if [ -f "ipc/namespace.c" ] && ! grep -qF 'EXPORT_SYMBOL(put_ipc_ns);' "ipc/namespace.c"; then
                sed -i '/^static struct ns_common \*ipcns_get(/i EXPORT_SYMBOL(put_ipc_ns);' "ipc/namespace.c"
            fi
        fi

        enable_config() {
            local cfg="$1"
            if grep -q "^${cfg}=y" "$DEFCONFIG"; then
                echo "  已启用: $cfg"
            elif grep -q "^# ${cfg} is not set" "$DEFCONFIG"; then
                sed -i "s/^# ${cfg} is not set$/${cfg}=y/" "$DEFCONFIG"
            else
                echo "${cfg}=y" >> "$DEFCONFIG"
            fi
        }
        config_defined() {
            local name="${1#CONFIG_}"
            grep -RqsE --include='Kconfig*' "^[[:space:]]*(menuconfig|config)[[:space:]]+${name}$" .
        }
        enable_config_if_defined() {
            local cfg="$1"
            if config_defined "$cfg"; then
                enable_config "$cfg"
            else
                echo "  当前内核未定义: $cfg, 跳过"
            fi
        }
        enable_config CONFIG_SYSVIPC
        enable_config CONFIG_POSIX_MQUEUE
        enable_config CONFIG_IPC_NS
        enable_config CONFIG_PID_NS
        enable_config CONFIG_DEVTMPFS
        enable_config_if_defined CONFIG_NETFILTER_XT_MATCH_ADDRTYPE
        enable_config_if_defined CONFIG_NETFILTER_XT_TARGET_LOG
        enable_config_if_defined CONFIG_NETFILTER_XT_MATCH_RECENT
        enable_config_if_defined CONFIG_IP_SET
        enable_config_if_defined CONFIG_IP_SET_HASH_IP
        enable_config_if_defined CONFIG_IP_SET_HASH_NET
        enable_config_if_defined CONFIG_NETFILTER_XT_SET
        enable_config_if_defined CONFIG_NETFILTER_XT_TARGET_REJECT
        enable_config_if_defined CONFIG_IP_NF_TARGET_REJECT
    )
fi

# ---------------- 8. NTSync(Droidspaces 需要) ----------------
if [ "$DROIDSPACES_NTSYNC" = "true" ]; then
    log "注入 NTSync 内核配置..."
    (
        cd "$REPO_ROOT/common"
        wget -q "https://raw.githubusercontent.com/Goldzxcbug/Droidspaces_Kernel_patch/refs/heads/main/NTsync/ntsync_base.patch"
        wget -q "https://raw.githubusercontent.com/Goldzxcbug/Droidspaces_Kernel_patch/refs/heads/main/NTsync/ntsync_compat_android16-6.12.patch"
        patch -p1 < "ntsync_base.patch" || true
        patch -p1 < "ntsync_compat_android16-6.12.patch" || true
    )
    sed -i '/CONFIG_NTSYNC is not set/d' "$DEFCONFIG"
    grep -q "^CONFIG_NTSYNC=y" "$DEFCONFIG" || echo "CONFIG_NTSYNC=y" >> "$DEFCONFIG"
fi

# ---------------- 9. BBG 防格机 ----------------
if [ "$USE_BBG" = "true" ]; then
    log "添加 BBG 防格机补丁..."
    (
        cd "$REPO_ROOT"
        curl -LSs https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh | bash || true
        echo "CONFIG_BBG=y" >> common/arch/arm64/configs/gki_defconfig
        sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' common/security/Kconfig
    )
fi

# ---------------- 10. Re-Kernel 驱动 ----------------
if [ "$USE_REKERNEL" = "true" ]; then
    log "集成 Re-Kernel..."
    REKERNEL_SRC="$WORK_ROOT/Re-Kernel"
    [ -d "$REKERNEL_SRC/.git" ] || git clone --depth 1 https://github.com/Sakion-Team/Re-Kernel.git "$REKERNEL_SRC"

    rm -rf "$REPO_ROOT/common/drivers/rekernel"
    mkdir -p "$REPO_ROOT/common/drivers/rekernel"
    cp -a "$REKERNEL_SRC/LKM-Source/." "$REPO_ROOT/common/drivers/rekernel/"

    REK_MAKEFILE="$REPO_ROOT/common/drivers/rekernel/Makefile"
    sed -i 's/^obj-m := rekernel\.o$/obj-$(CONFIG_REKERNEL) += rekernel.o/' "$REK_MAKEFILE"
    grep -qF 'ccflags-$(CONFIG_REKERNEL_LEGACY_NETLINK) += -DLEGACY_NETLINK' "$REK_MAKEFILE" \
        || echo 'ccflags-$(CONFIG_REKERNEL_LEGACY_NETLINK) += -DLEGACY_NETLINK' >> "$REK_MAKEFILE"
    sed -i '/^[[:space:]]*depends on MODULES[[:space:]]*$/d' "$REPO_ROOT/common/drivers/rekernel/Kconfig"

    REK_KCONFIG="$REPO_ROOT/common/drivers/Kconfig"
    grep -qF 'source "drivers/rekernel/Kconfig"' "$REK_KCONFIG" \
        || sed -i '/^endmenu$/i source "drivers/rekernel/Kconfig"' "$REK_KCONFIG"
    REK_DRV_MAKEFILE="$REPO_ROOT/common/drivers/Makefile"
    grep -qF 'obj-$(CONFIG_REKERNEL) += rekernel/' "$REK_DRV_MAKEFILE" \
        || echo 'obj-$(CONFIG_REKERNEL) += rekernel/' >> "$REK_DRV_MAKEFILE"

    sed -i 's|#include <../android/binder_internal.h>|#include "../android/binder_internal.h"|g' "$REPO_ROOT/common/drivers/rekernel/rekernel_binder.c"
    grep -qF '#include <linux/seq_file.h>' "$REPO_ROOT/common/drivers/rekernel/rekernel_binder.c" \
        || sed -i '/#include <linux\/kprobes.h>/a #include <linux/seq_file.h>' "$REPO_ROOT/common/drivers/rekernel/rekernel_binder.c"

    grep -q '^CONFIG_REKERNEL=y$' "$DEFCONFIG" || echo "CONFIG_REKERNEL=y" >> "$DEFCONFIG"
    grep -q '^CONFIG_REKERNEL_NETWORK=y$' "$DEFCONFIG" || echo "CONFIG_REKERNEL_NETWORK=y" >> "$DEFCONFIG"
fi

# ---------------- 11. 内核配置 ----------------
log "追加内核配置..."
cat >> "$DEFCONFIG" <<'EOF'
CONFIG_TMPFS_XATTR=y
CONFIG_TMPFS_POSIX_ACL=y
EOF
if [ "$KSU_VARIANT" != "None" ]; then
    echo "CONFIG_KSU=y" >> "$DEFCONFIG"
fi

if [ "$USE_KPM" != "disabled" ] &&
   { [ "$KSU_VARIANT" = "SukiSU" ] || [ "$KSU_VARIANT" = "ReSukiSU" ] || [ "$KSU_VARIANT" = "Next" ]; }; then
    if ! grep -RqsE '^[[:space:]]*config[[:space:]]+KPM([[:space:]]|$)' "$REPO_ROOT/common" "$REPO_ROOT/KernelSU" 2>/dev/null; then
        die "已请求 KPM, 但当前 KernelSU 代码未声明 CONFIG_KPM"
    fi
    echo "CONFIG_KPM=y" >> "$DEFCONFIG"
elif [ "$USE_KPM" != "disabled" ]; then
    warn "KPM 仅支持 SukiSU/ReSukiSU/Next 变体, 目前已忽略"
fi

sed -i 's/check_defconfig//' "$REPO_ROOT/common/build.config.gki" 2>/dev/null || true

if [ "$ENABLE_SUSFS" = "true" ]; then
    cat >> "$DEFCONFIG" <<'EOF'
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

# 设备配置补充(与设备原厂 config 对齐, 见 config/device.fragment)
DEVICE_FRAGMENT="$SCRIPT_DIR/config/device.fragment"
if [ -f "$DEVICE_FRAGMENT" ]; then
    log "应用设备配置补充 $DEVICE_FRAGMENT:"
    sed -E 's/^/  /' "$DEVICE_FRAGMENT"
    sort -u "$DEVICE_FRAGMENT" >> "$DEFCONFIG"
fi

# TLS=m (与设备对齐): tls.ko 不在 GKI 声明列表, dist 会报 "built but not copied"。
# 补进 kernel_aarch64 的 module_implicit_outs; 若补丁失败则自动移除 TLS=m 配置。
if grep -q '^CONFIG_TLS=m$' "$DEFCONFIG"; then
    if sed -i 's/^[[:space:]]*module_implicit_outs = get_gki_modules_list("arm64") + get_kunit_modules_list("arm64"),\s*$/    module_implicit_outs = get_gki_modules_list("arm64") + get_kunit_modules_list("arm64") + ["net\/tls\/tls.ko"],/' \
           "$REPO_ROOT/common/BUILD.bazel" \
        && grep -q 'net/tls/tls.ko' "$REPO_ROOT/common/BUILD.bazel"; then
        log "已将 net/tls/tls.ko 声明进 module_implicit_outs"
    else
        warn "module_implicit_outs 补丁失败, 自动移除 TLS=m"
        sed -i '/^CONFIG_TLS=m$/d' "$DEFCONFIG"
    fi
fi

# ---------------- 12. 内核名称(版本名 / KMI 后缀) ----------------
log "设置内核版本名..."
(
    cd "$REPO_ROOT"
    if [ -f "build/build.sh" ]; then
        sed -i 's/-dirty//' ./common/scripts/setlocalversion
    else
        sed -i '/^[[:space:]]*"protected_exports_list"[[:space:]]*:[[:space:]]*"android\/abi_gki_protected_exports_aarch64",$/d' ./common/BUILD.bazel
        sed -i '/kmi_symbol_list_strict_mode/d' ./common/BUILD.bazel
        rm -rf ./common/android/abi_gki_protected_exports_*
        sed -i "/stable_scmversion_cmd/s/-maybe-dirty//g" ./build/kernel/kleaf/impl/stamp.bzl || true
    fi
)

VERSION_INPUT="$(echo "$VERSION_NAME" | tr -d '[:space:]')"
if [ -n "$VERSION_INPUT" ]; then
    log "自定义版本名: $VERSION_INPUT"
    CLEAN_VERSION="$(echo "$VERSION_INPUT" | sed -E 's/^[0-9]+\.[0-9]+\.[0-9]+//')"
    (
        cd "$REPO_ROOT"
        perl -i -0777 -pe 's/(.*)echo "\$\{KERNELVERSION\}\$\{file_localversion\}\$\{config_localversion\}\$\{LOCALVERSION\}\$\{scm_version\}"/$1echo "\$\{KERNELVERSION}'"${CLEAN_VERSION}"'"/s' ./common/scripts/setlocalversion 2>/dev/null || true
        sed -i "\$s|echo \"\$res\"|echo \"${CLEAN_VERSION}\"|" ./common/scripts/setlocalversion 2>/dev/null || true
        sed -i '/^CONFIG_LOCALVERSION=/ s/="\([^"]*\)"/="'"$CLEAN_VERSION"'"/' ./common/arch/arm64/configs/gki_defconfig
    )
elif [ ! -f "$REPO_ROOT/build/build.sh" ]; then
    BID="ab$((RANDOM % 90000000 + 10000000))"
    GHASH="$(git -C "$REPO_ROOT/common" rev-parse --verify HEAD | cut -c1-13)"
    KMI_SUFFIX="-android16-5-g${GHASH}-${BID}"
    (
        cd "$REPO_ROOT/common"
        perl -i -0777 -pe 's/(.*)echo "\$\{KERNELVERSION\}\$\{file_localversion\}\$\{config_localversion\}\$\{LOCALVERSION\}\$\{scm_version\}"/$1echo "\$\{KERNELVERSION}'"${KMI_SUFFIX}"'\$\{config_localversion\}"/s' ./scripts/setlocalversion 2>/dev/null || true
    )
fi

# ---------------- 13. 自定义构建时间 ----------------
if [ "$BUILD_TIME" = "N" ] || [ "$BUILD_TIME" = "n" ]; then
    BUILD_TIME=""
fi
if [ -n "$BUILD_TIME" ]; then
    TIME_REGEX='^(Mon|Tue|Wed|Thu|Fri|Sat|Sun) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) (0[1-9]|[12][0-9]|3[01]) ([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9] UTC [0-9]{4}$'
    [[ "$BUILD_TIME" =~ $TIME_REGEX ]] || die "构建时间格式错误, 必须形如 'Sun Dec 01 08:10:00 UTC 2024'"
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

# ---------------- 14. 编译(失败自动重试 1 次) ----------------
log "开始编译 (bazel/kleaf, 首次约 30-90 分钟)..."
LOG_DIR="$WORK_ROOT/build-logs"
mkdir -p "$LOG_DIR"

# 先统一生成 ksu.fragment(defconfig 修改 diff 到 fragment, 避免 bazel trim 检查失败)
FRAG="$REPO_ROOT/common/arch/arm64/configs/ksu.fragment"
diff "$BASELINE" "$DEFCONFIG" | grep '^>' | sed 's/^> //; s/^[[:space:]]*//' > "$FRAG" || true
cp "$BASELINE" "$DEFCONFIG"
echo "=== ksu.fragment ==="
cat "$FRAG"
echo "====================="
FRAG_FLAG=""
[ -s "$FRAG" ] && FRAG_FLAG="--defconfig_fragment=//common:arch/arm64/configs/ksu.fragment"
mkdir -p "$WORK_ROOT/bazel-cache"

compile() { # $1=attempt
    set -o pipefail
    (
        cd "$REPO_ROOT"
        sed -i 's/BUILD_SYSTEM_DLKM=1/BUILD_SYSTEM_DLKM=0/' ./common/build.config.gki.aarch64 || true
        sed -i '/MODULES_ORDER=android\/gki_aarch64_modules/d' ./common/build.config.gki.aarch64 || true
        sed -i '/KMI_SYMBOL_LIST_STRICT_MODE/d' ./common/build.config.gki.aarch64 || true

        tools/bazel build --disk_cache="$WORK_ROOT/bazel-cache" --config=fast --lto=none $FRAG_FLAG \
            //common:kernel_aarch64_dist
        strings ./bazel-bin/common/kernel_aarch64/Image 2>/dev/null | grep -m1 'Linux version' || true
    ) 2>&1 | tee "$LOG_DIR/compile-attempt-$1.log"
}

BUILD_STATUS=1
for attempt in 1 2; do
    if compile "$attempt"; then
        BUILD_STATUS=0
        break
    fi
    [ "$attempt" = "1" ] && warn "编译失败(第 1 次), 90 秒后重试... 日志: $LOG_DIR/compile-attempt-1.log"
    sleep 90
done
[ "$BUILD_STATUS" = "0" ] || die "编译失败! 日志见 $LOG_DIR/"

# ---------------- 15. 打包 ----------------
log "打包产物..."
mkdir -p "$OUT_DIR"
SRC_IMG="$REPO_ROOT/bazel-bin/common/kernel_aarch64"
[ -f "$SRC_IMG/Image" ] || die "未找到编译产物 Image ($SRC_IMG)"

# 导出构建产物真实的解析配置(用于与设备 config 精确对比)
# 必须与主构建使用相同的 fragment, 否则导出的不是真实构建配置
(
    cd "$REPO_ROOT"
    tools/bazel build --disk_cache="$WORK_ROOT/bazel-cache" --config=fast --lto=none $FRAG_FLAG \
        //common:kernel_aarch64_config >/dev/null 2>&1 || true
)
KCFG="$(find -H "$SRC_IMG" "$REPO_ROOT/bazel-bin" -maxdepth 6 \
    \( -name 'kernel_config' -o -name '.config' \) -type f 2>/dev/null | head -n1)"
if [ -n "$KCFG" ]; then
    cp "$KCFG" "$OUT_DIR/kernel.config"
    log "已导出真实内核配置: $KCFG ($(wc -l < "$OUT_DIR/kernel.config") 行)"
else
    warn "未能在构建产物中找到 kernel_config (不影响内核构建, 仅影响设备配置对比)"
fi

BASE="${ANDROID_VERSION}-${KERNEL_VERSION}.${SUBLEVEL}-${OS_PATCH_LEVEL}"

# AnyKernel3
ANYKERNEL3="$WORK_ROOT/AnyKernel3"
if [ ! -d "$ANYKERNEL3" ]; then
    git clone -b gki-2.0 https://github.com/WildKernels/AnyKernel3.git "$ANYKERNEL3"
fi
rm -rf "$ANYKERNEL3/.git"
cd "$ANYKERNEL3"
rm -f Image
cp "$SRC_IMG/Image" ./Image
zip -r -q "$OUT_DIR/${BASE}-AnyKernel3.zip" ./*
cd "$SCRIPT_DIR"

if [ "$ARTIFACT_MODE" = "all" ]; then
    cp "$SRC_IMG/Image" "$OUT_DIR/Image"
    if [ -f "$SRC_IMG/Image.lz4" ]; then
        cp "$SRC_IMG/Image.lz4" "$OUT_DIR/Image.lz4"
    else
        warn "无 Image.lz4"
    fi
    gzip -n -k -f -9 "$OUT_DIR/Image"

    MKBOOTIMG="$REPO_ROOT/tools/mkbootimg/mkbootimg.py"
    AVBTOOL="$REPO_ROOT/prebuilts/kernel-build-tools/linux-x86/bin/avbtool"
    TESTKEY="$REPO_ROOT/prebuilts/kernel-build-tools/linux-x86/share/avb/testkey_rsa2048.pem"
    [ -f "$MKBOOTIMG" ] || die "未找到 mkbootimg.py"
    [ -x "$AVBTOOL" ] || die "未找到 avbtool"
    if [ ! -f "$TESTKEY" ]; then
        warn "无官方 testkey, 生成临时签名密钥"
        openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 > "$WORK_ROOT/avb-testkey.pem" 2>/dev/null || true
        TESTKEY="$WORK_ROOT/avb-testkey.pem"
    fi

    make_boot() { # $1=内核文件 $2=输出名
        python3 "$MKBOOTIMG" --header_version 4 --kernel "$1" --output "$OUT_DIR/$2"
        "$AVBTOOL" add_hash_footer --partition_name boot --partition_size $((64 * 1024 * 1024)) \
            --image "$OUT_DIR/$2" --algorithm SHA256_RSA2048 --key "$TESTKEY"
    }
    make_boot "$OUT_DIR/Image"      "${BASE}-boot.img"
    make_boot "$OUT_DIR/Image.gz"   "${BASE}-boot-gz.img"
    [ -f "$OUT_DIR/Image.lz4" ] && make_boot "$OUT_DIR/Image.lz4" "${BASE}-boot-lz4.img"
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
    echo "补丁级别      : $OS_PATCH_LEVEL"
    echo "构建时间戳    : $DATESTR"
    echo "KernelSU 变体 : $KSU_VARIANT (v$KSU_VERSION, commit $KSU_COMMIT, $KSU_DATE)"
    echo "SUSFS         : $ENABLE_SUSFS (commit $SUSFS_COMMIT, $SUSFS_DATE)"
    echo "KPM           : $USE_KPM"
    echo "Droidspaces   : $DROIDSPACES (NTSync=$DROIDSPACES_NTSYNC)"
    echo "ZRAM          : $USE_ZRAM   BBG=$USE_BBG   Re-Kernel=$USE_REKERNEL"
    echo "CVE-2026-43499: $CVE_2026_43499_PATCH   一加8E=$SUPP_OP"
    echo "版本名        : ${VERSION_NAME:-无}"
    echo "镜像源        : $MIRROR"
} > "$OUT_DIR/INFO.txt"

log "构建完成!"
echo ""
echo "===================== 产物 ($OUT_DIR) ====================="
ls -lh "$OUT_DIR"
echo "============================================================"
