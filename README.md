# gki-build-nx809j

自动构建 **谷歌最新 `android16-6.12` GKI 内核**(固定 6.12,集成 KernelSU / ReSukiSU / SukiSU / Next + SUSFS)的仓库,目标设备 **NX809J(红魔 11 系列)**。

流程与功能开关对齐参考 [zzh20188/GKI_KernelSU_SUSFS](https://github.com/zzh20188/GKI_KernelSU_SUSFS) 的 `build.yml`,增强点:

1. **自动识别最新版本**:构建前自动探测 Google 最新的 `android16-6.12-YYYY-MM` 月度发布分支(不再写死旧版本),同步后以 `common/Makefile` 的 SUBLEVEL 为准(当前约 `6.12.92`);也支持 `tip` / `lts` / 指定月份。
2. **镜像可选**:`ustc`(中科大)/ `nju`(南大)/ `github` 直连,国内加速。

---

## 方式一:GitHub Actions(推荐,零环境)

仓库推到 GitHub 后:

1. **Actions → Build android16-6.12 GKI + KernelSU/SUSFS → Run workflow**;
2. 选择参数,点 Run;
3. 完成后在该 run 的 **Artifacts** 下载产物。

> 每周日 20:35 UTC 自动构建一次最新版本(`auto` + `Official` + 默认开关)。

## 方式二:本地 WSL2 / Linux

```powershell
.\build.ps1 --mirror ustc
```

```bash
bash build.sh --mirror ustc
```

首次运行 repo sync(国内镜像约 20~60 分钟)+ 编译(30~90 分钟),磁盘 ≥ 25GB、内存 ≥ 16GB。

---

## 参数(GitHub Actions 的输入 = build.sh 的选项)

| 输入/选项 | 默认 | 说明 |
|---|---|---|
| `patch_level` | `auto` | 安全补丁级别:`auto`=最新月度发布 / `tip`=分支头(最新代码)/ `lts` / `2026-09` 等具体月份 |
| `kernelsu_variant` | `Official` | `Official` / `ReSukiSU` / `SukiSU` / `Next`;SukiSU 最新版不兼容 6.12,慎选 |
| `version_name` | 空 | 自定义版本名(显示在 `uname -r`) |
| `build_time` | 当前 UTC | 伪装构建时间,如 `Sun Dec 01 08:10:00 UTC 2024` |
| `use_kpm` | `disabled` | KPM 功能(仅 SukiSU/ReSukiSU/Next 变体;`patched` 上游尚未支持) |
| `droidspaces` | `off` | Droidspaces 容器支持(6.12:开/关) |
| `droidspaces_ntsync` | off | 需 Droidspaces 开启 |
| `artifact_upload_mode` | 上传全部 | `anykernel3` 模式只出 AnyKernel3.zip |
| `use_zram` | off | ZRAM 增强:6.12 上游未适配(zzh 的 6.12 矩阵也关闭),选择后会提示并跳过 |
| `use_bbg` | off | BBG 防格机 |
| `use_rekernel` | off | Re-Kernel 驱动 |
| `cve_2026_43499_patch` | off | CVE-2026-43499/53163 rtmutex 修复链(已内置补丁,≥6.12.95 自动跳过) |
| `cancel_susfs` | off | 禁用 SUSFS |
| `supp_op` | off | 一加 8E 支持 |
| `mirror` | `ustc` | 本地构建用;Actions 中固定 `google` |
| `slim` | on | 精简 sync,跳过 GBL(引导加载器)项目,省 ~10GB 磁盘 |
| `with_manager` | off | 顺带下载对应变体的管理器 APK |

其余(构建时间校验、KMI 后缀、AnyKernel3、AVB 签名、boot 镜像 gz/lz4)均为固定内置行为。

## 产物(`work/out/`)

| 文件 | 用途 |
|---|---|
| `android16-6.12.<SUB>-<补丁级别>-boot.img` | 标准 boot 镜像(fastboot flash boot) |
| `...-boot-gz.img` / `...-boot-lz4.img` | gz / lz4 压缩内核的 boot 镜像 |
| `...-AnyKernel3.zip` | recovery 刷入包 |
| `Image` / `Image.gz` / `Image.lz4` | 裸内核(仅"上传全部"模式) |
| `INFO.txt` | 构建完整信息(内核/KSU/SUSFS/各开关) |

## NX809J 刷入说明(务必先备份!)

1. 确认设备当前内核:`adb shell uname -r`(形如 `6.12.x-android16-5-g...`)。
2. GKI 设备,`boot` 分区无 Ramdisk 时直接:
   ```bash
   adb reboot bootloader
   fastboot flash boot <boot.img>
   fastboot reboot
   ```
3. 也可把 `AnyKernel3.zip` 放到自定 Recovery 刷入。
4. 解锁 bootloader + 关闭 AVB 校验的设备一般接受 testkey 签名;若无限重启,刷回官方 boot 即可。
5. 刷完安装对应管理器:官方 KernelSU 在 [Releases](https://github.com/tiann/KernelSU/releases) 下载(或构建时勾 `with_manager`)。

## 目录结构

```
build.sh                # 主构建脚本(检测->同步->补丁->编译->打包)
detect.sh               # 自动探测最新 android16-6.12 分支(auto/tip/lts/指定月)
config.env              # 默认配置(命令行/环境变量优先)
build.ps1               # Windows 入口(WSL2)
security_patch/         # CVE-2026-43499/53163 修复链(内置)
scripts/susfs_fixes/    # SUSFS 补丁应用脚本(与上游逐字一致)
.github/workflows/build.yml  # GitHub Actions 主入口
```

## 说明与致谢

- 上游脚本与补丁来源: [zzh20188/GKI_KernelSU_SUSFS](https://github.com/zzh20188/GKI_KernelSU_SUSFS)(GPL-2.0);`security_patch/` 与 `scripts/susfs_fixes/` 为其仓库原样复制,仅作构建引用。
- KernelSU: https://github.com/tiann/KernelSU
- SUSFS: https://gitlab.com/simonpunk/susfs4ksu
- AnyKernel3: https://github.com/WildKernels/AnyKernel3
- Droidspaces: https://github.com/ravindu644/Droidspaces-OSS
