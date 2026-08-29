# gki-build-nx809j

自动构建 **谷歌最新 `android16-6.12` GKI 内核**(集成 KernelSU / ReSukiSU / SukiSU / Next + SUSFS)的仓库,目标设备 **NX809J(红魔 11 系列)**。

流程参考 [zzh20188/GKI_KernelSU_SUSFS](https://github.com/zzh20188/GKI_KernelSU_SUSFS) 的 `build.yml`,做了两点增强:

1. **自动识别最新版本**:每次构建前自动探测 Google 最新的 `android16-6.12-YYYY-MM` 月度发布分支(不再写死 6.12.23/30/38/58 这类旧版本),同步后以 `common/Makefile` 的 SUBLEVEL 为准(当前约 `6.12.92`)。
2. **镜像可选**:`ustc`(中科大)/ `nju`(南大)/ `google`(官方),国内直连加速。

---

## 方式一:GitHub Actions(推荐,推荐零环境)

把本仓库推到 GitHub 后:

1. 打开仓库 **Actions → Build android16-6.12 GKI + KernelSU/SUSFS → Run workflow**;
2. 选好参数(`variant` / `source` / `susfs`),点 Run;
3. 构建完成后在本次 run 的 **Artifacts** 里下载产物。

> 参数说明:
> - `variant`:**Official**(默认,最稳)/ ReSukiSU / SukiSU / Next。注意 SukiSU 最新版目前与 6.12 不兼容,官方和 ReSukiSU 都支持 6.12。
> - `source`:**release**(默认)= 谷歌最新月度 GKI 发布分支;`tip` = `android16-6.12` 分支头(最新代码)。
> - 每周日 20:35 UTC 也会自动构建一次最新版本。

## 方式二:本地 WSL2 / Linux

```powershell
# Windows: 双击或执行(自动复制到 WSL2 并运行)
.\build.ps1 --mirror ustc
```

或 Linux 下直接:

```bash
bash build.sh --mirror ustc
```

首次运行会 `repo sync`(国内镜像约 20~60 分钟)+ 编译(30~90 分钟),请确保磁盘 ≥ 25GB、内存 ≥ 16GB。

## 产物(`work/out/`)

| 文件 | 用途 |
|---|---|
| `android16-6.12.<SUB>-<月份>-boot.img` | 标准 boot 镜像(fastboot flash boot) |
| `...-boot-gz.img` / `...-boot-lz4.img` | gz / lz4 压缩内核的 boot 镜像 |
| `...-AnyKernel3.zip` | recovery 刷入包(AnyKernel3) |
| `Image` / `Image.gz` / `Image.lz4` | 裸内核 |
| `INFO.txt` | 本次构建的内核/KSU/SUSFS 版本信息 |

## NX809J 刷入说明(务必先备份!)

1. 先确认设备当前内核:`adb shell uname -r`(形如 `6.12.x-android16-5-g...`)。
2. 该设备是 GKI,若 `boot` 分区无 Ramdisk,直接:
   ```bash
   adb reboot bootloader
   fastboot flash boot <boot.img>
   fastboot reboot
   ```
3. 也可把 `AnyKernel3.zip` 放到 Recovery 刷入(lineage/TWRP 类自定 Recovery)。
4. 解锁 bootloader + 关闭 AVB 校验的设备一般可接受 testkey 签名;若刷入后无限重启,`fastboot flash boot` 刷回官方 boot 即可救砖。
5. 刷完安装对应管理器 APK(官方 KernelSU 需要在 [KernelSU Releases](https://github.com/tiann/KernelSU/releases) 下载),或构建时勾选 `with_manager`。

## 目录结构

```
build.sh          # 主构建脚本(自动识别->同步->打补丁->编译->打包)
detect.sh         # 自动探测最新 android16-6.12 发布分支
config.env        # 默认配置(命令行参数优先)
build.ps1         # Windows 入口(WSL2)
.github/workflows/build.yml   # GitHub Actions 主入口
```

## 参考

- 上游脚本: https://github.com/zzh20188/GKI_KernelSU_SUSFS (MIT/GPL 允许范围,仅供学习参考)
- KernelSU: https://github.com/tiann/KernelSU
- SUSFS: https://gitlab.com/simonpunk/susfs4ksu
- AnyKernel3: https://github.com/WildKernels/AnyKernel3
