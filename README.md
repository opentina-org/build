# OpenTina 构建说明（`build/`）

本目录为固件与镜像构建入口：源码在 `sources/`，产物在 `output/<BOARD_NAME>/`，板级配置在 `configs/`。

---

## 前置条件

**宿主机（默认）**

最小依赖（Debian / Ubuntu，与 `docker/Dockerfile` 对齐，外加 U-Boot `pylibfdt` 需要的 `swig`）：

```shell
sudo apt install -y \
    bc bison build-essential ca-certificates chrpath cpio device-tree-compiler \
    dosfstools flex g++-aarch64-linux-gnu gcc-aarch64-linux-gnu \
    genimage git libgnutls28-dev libssl-dev make mtools patch perl \
    python3 python3-setuptools rsync swig u-boot-tools wget xz-utils
```

其中 **`chrpath`** 为 Yocto/BitBake `HOSTTOOLS` 所需。若未装系统包，`sources/meta-opentina/opentina-build.sh` 会尝试解压到 `~/.local/bin`。

**Ubuntu 24.04+ / Yocto：** AppArmor 默认限制无特权 user namespace，BitBake 会报 `User namespaces are not usable`。一次性放开：

```shell
echo 'kernel.apparmor_restrict_unprivileged_userns=0' | sudo tee /etc/sysctl.d/99-bitbake-userns.conf
sudo sysctl -p /etc/sysctl.d/99-bitbake-userns.conf
```

`opentina-build.sh` 也会在缺少该能力时尝试用 Docker/`sudo -n` 自动写入上述 sysctl。

若整机构建包在 **`proxychains4`** 下跑：sysctl 已是 `0` 时一般没问题；不要用 CLI `unshare` 自行探测（`LD_PRELOAD` 多线程会导致误报）。网络代理更建议只包下载步骤，而不是整个 `bitbake`。

如果**不**走 Docker 而直接在宿主跑 debian / ubuntu rootfs（设 `OPENTINA_DEBIAN_USE_DOCKER=0` 或 `OPENTINA_UBUNTU_USE_DOCKER=0`），再补：

```shell
sudo apt install -y debootstrap qemu-user-static binfmt-support
```

其余：

- AArch64 交叉工具链（默认 `aarch64-linux-gnu-gcc`，板级 `OPENTINA_CROSS_COMPILE` 可覆盖）。
- 已克隆的源码树（见下文 `./build.sh init`）。

**可选：Docker 构建环境**

- 安装 [Docker](https://docs.docker.com/get-docker/)，用于 `OPENTINA_DOCKER=1` 或 `--docker` 时在 **Ubuntu 24.04** 镜像内构建（镜像内已含 `gcc-aarch64-linux-gnu`、`genimage` 等，见 `docker/Dockerfile`）。

---

## 快速开始

```bash
cd /path/to/build    # 本 README 所在目录

# 1. 拉取源码（默认 manifest，可换路径）
./build.sh init

# 2. 查看支持的板子与 rootfs 类型
./build.sh targets

# 3. 编译（将 BOARD_NAME 换成 targets 里列出的名字）
./build.sh <BOARD_NAME> build
```

产物示例：`output/radxa_a7a/sdcard.img`、`rootfs.ext2`、`Image.gz`、dtb、`u-boot.fex` 等。

---

## Buildroot（组件 `br2`）

- **配方位置**：`scripts/recipes.sh` 中的 **`build_br2`** / **`clean_br2`**（组件名用 **`br2`**，避免与命令行 **`OPENTINA_ROOTFS=buildroot`** 混淆）。
- **板级变量**：`configs/<板>/config` 里 **`BUILDROOT_DEFCONFIG`**（默认 `br2_opentina.defconfig`，与 `config` 同目录）。
- **defconfig 模板**：`configs/*/br2_opentina.defconfig` — AArch64 + Bootlin 外部工具链 + **无内核**（内核由本仓库 `linux` 组件构建）+ **ext2 rootfs**。
- **仅构建 rootfs**：`./build.sh <BOARD> build br2`（需已 `init` 克隆 `sources/buildroot`）。
- **分区**：`configs/*/partitions.cfg` 中 **`partition root`** 使用镜像 **`rootfs.ext2`**，起始偏移 **`148M`**（紧接 128 MiB 的 `boot` 分区之后）。若板卡上块设备节点与 `mmcblk0p4` 不一致，请同步修改板级 **`EXTLINUX_ROOT`**（见下节）。

---

## Ubuntu rootfs（组件 `ubuntu`）

- **源码**：manifest 中的 **`openaw/ubuntu`** → `sources/ubuntu`（`revision=master`）。
- **配方**：`scripts/recipes.sh` 中的 **`build_ubuntu`** / **`clean_ubuntu`**；命令行使用 **`OPENTINA_ROOTFS=ubuntu`** 时，默认组件链里的 rootfs 步骤为 **`ubuntu`** 而非 **`br2`**。
- **构建**：在 x86 宿主机上优先调用 `sources/ubuntu/docker/build-rootfs.sh`（需本机 **Docker**）；原生 **arm64** 可设 **`OPENTINA_UBUNTU_USE_DOCKER=0`** 后直接跑 `mk-base-ubuntu.sh` / `mk-ubuntu-rootfs.sh`。
- **环境变量**（可选，可在板级 `config` 中 export）：**`UBUNTU_RELEASE`**（默认 `24.04`）、**`UBUNTU_ARCH`**（默认 `arm64`）、**`OPENTINA_MOTD_BANNER_FILE`**（自定义登录 ASCII/文本，见 `sources/ubuntu/readme.md`）。
- **产物**：仓库内 `ubuntu-rootfs.ext4` 拷贝为 **`output/<BOARD>/rootfs.ext2`**，与 Buildroot 共用 **`partitions.cfg`** 的 root 分区。若已构建 **`linux`**，会把 `.staging-linux-modules` 中的 `*.ko` 叠进该镜像。
- **示例**：`./build.sh <BOARD> ubuntu build`；仅 rootfs：`./build.sh <BOARD> ubuntu build ubuntu`。
- **内核**：`OPENTINA_ROOTFS=ubuntu` 构建 **`linux`** 时会在 `LINUX_CONFIG`（如 `a733_minimal_defconfig`）之上合并 **`configs/common/linux-systemd.fragment`**（`CONFIG_TMPFS`、`CONFIG_UNIX` 等）。精简 defconfig 单独用于 systemd 会出现 `tmpfs: Unknown parameter 'mode'`、`Failed to find module 'unix'` 并卡在 *Failed to mount API filesystems*。可用环境变量 **`LINUX_SYSTEMD_FRAGMENT`** 覆盖片段路径。

---

## Debian rootfs（组件 `debian`）

- **源码**：manifest 中的 **`openaw/debian`** → `sources/debian`（`revision=master`）。
- **配方**：`scripts/recipes.sh` 中的 **`build_debian`** / **`clean_debian`**；**`OPENTINA_ROOTFS=debian`** 时默认组件链使用 **`debian`** 替代 **`br2`**。
- **构建**：x86 宿主机优先 **`sources/debian/docker/build-rootfs.sh`**（默认 **`MAKE_EXT4=1`**）；原生 arm64 可 **`OPENTINA_DEBIAN_USE_DOCKER=0`** 后执行 **`mk-lite-rootfs.sh`**。
- **环境变量**（可选）：**`DEBIAN_RELEASE`**（默认 **`trixie`**，亦可用 **`bookworm`**）、**`DEBIAN_ARCH`**（默认 **`arm64`**）、**`ROOTFS_EXT4_MB`**、**`DEBIAN_MIRROR`** 等（见 `sources/debian/readme.md`）。
- **产物**：`sources/debian/out/debian-*-lite-*.ext4`（取最新）拷贝为 **`output/<BOARD>/rootfs.ext2`**。若已构建 **`linux`**，同样叠入 staged `*.ko`。
- **示例**：`./build.sh <BOARD> debian build`；仅 rootfs：`./build.sh <BOARD> debian build debian`。
- **内核**：与 Ubuntu 相同，**`debian`** 构建 **`linux`** 时合并 **`linux-systemd.fragment`**。
- **启动参数**：**`build_bootfs`** 会在 extlinux 的 **`append`** 中追加 **`systemd.gpt_auto=0`**，避免 systemd 自动挂载不存在的 `/boot`（GPT 上 FAT 启动区由 U-Boot 使用，不在 rootfs 内挂载）。

---

## OEM 注入（客户扩展安装包与 overlay）

让客户在不 fork 本仓库的前提下，把私有 `.deb`、文件 overlay、收尾脚本注入到 **Debian/Ubuntu** rootfs。

- **适用范围**：`OPENTINA_ROOTFS=debian` 或 `ubuntu`，且走 **buildx** 路径（默认）；非 buildx 的 fallback（`build-rootfs.sh` debootstrap、`mk-lite-rootfs.sh` 等）若检测到 OEM 请求会**直接报错**——避免客户资产被静默丢弃。
- **目录约定**：

  ```
  <OEM_DIR>/
    packages/            *.deb — 由 apt-get install ./packages/*.deb 安装
    rootfs-overlay/      cp -a 到 / （文件树合并）
    post.sh              chroot 内执行（chmod +x；可选）
  ```

- **路径选择优先级**：环境变量 **`OPENTINA_OEM_DIR`** > 板级 **`configs/<板>/oem/`** > 无（no-op）。
- **依赖策略**：**不使用 `apt-get -f install`**——`packages/*.deb` 的依赖必须由 base apt 源（trixie/noble main）或同目录下的其它 `.deb` 共同满足；不能满足时 `docker build` 直接失败，立即暴露缺失依赖，避免镜像被 apt 隐式修复弄脏。
- **与 `EXTRA_DEBS` 的区别**：**`EXTRA_DEBS`** 用于从上游 apt 源拉额外公开包；OEM 用于客户私有 / 闭源 / 自编译产物。两者可并存。
- **示例**：

  ```shell
  OPENTINA_OEM_DIR=/path/to/oem ./build.sh <BOARD> debian build debian
  ```

- **回归测试**：`tests/oem/build-test-debs.sh` 生成两套样例 bundle（`good/` 依赖可解；`broken/` 故意 `Depends: nonexistent-…`），用于验证 happy-path 安装 + fail-fast 行为。详见 `sources/debian/readme.md` 与 `sources/ubuntu/readme.md` 中对应章节。

---

## Yocto rootfs（组件 `yocto`）

- **源码**：manifest 中的 **`openaw/meta-opentina`** → `sources/meta-opentina`（`revision=master`）。首次构建会由 **`opentina-build.sh`** 自动执行 **`yocto-init.sh`**，在 **`sources/yocto/`** 下拉取 Poky / meta-openembedded（体积大，见 layer 内 **README.md**）。
- **配方**：**`build_yocto`** / **`clean_yocto`** 调用 **`sources/meta-opentina/opentina-build.sh`**；**`OPENTINA_ROOTFS=yocto`** 时默认组件链使用 **`yocto`** 替代 **`br2`**。
- **配置**（可选，板级 `config` 或环境变量）：
  - **`OPENTINA_YOCTO_PROFILE`**：`minimal`（默认，**`opentina-image-minimal`**）或 **`qt`**（需 **`yocto-init.sh --qt`**，**`opentina-image-qt`**）
  - **`YOCTO_MACHINE`** / **`OPENTINA_YOCTO_MACHINE`**：默认 **`a733-aiot`**（layer 当前机器名；与 OpenTina 板级 **`BOARD_NAME`** 独立，内核仍由本仓库 **`linux`** 组件构建）
  - **`OPENTINA_YOCTO_DIR`**：Yocto 工作区，默认 **`sources/yocto`**
- **产物**：**`sources/yocto/build-opentina/tmp/deploy/images/<MACHINE>/opentina-image-*-<MACHINE>.ext4`** → **`output/<BOARD>/rootfs.ext2`**。若已构建 **`linux`**，叠入 staged `*.ko`。
- **示例**：`./build.sh <BOARD> yocto build yocto`（仅 rootfs，耗时长）；完整镜像：`./build.sh <BOARD> yocto build`
- **内核**：与 Ubuntu/Debian 相同，**`yocto`** 构建 **`linux`** 时合并 **`linux-systemd.fragment`**（`CONFIG_NET`、`CONFIG_UNIX`、`CONFIG_TMPFS` 等）。未合并时 sysvinit/udev/dbus 会报 **`Function not implemented`**、`/var/volatile` 失败。
- **默认登录**：**`root` / `root`**，**`opentina` / `opentina`**（`conf/include/opentina-default-users.inc`，镜像构建后处理写入 shadow）。可在 `local.conf` 覆盖 **`OPENTINA_ROOT_PASSWORD`** 等。SSH 已启用 **`allow-root-login`**。
- **注意**：**不要用 root 跑 bitbake**；**`OPENTINA_DOCKER=1`** 的 OpenTina 镜像未预装完整 Yocto 宿主机依赖，建议在**宿主机**编 **`yocto`** 组件。Layer 阶段为 **rootfs-only**（**`linux-dummy`**），与 **`linux` / `uboot` / `atf`** 组件并行不冲突。
- **若报 `meta-openembedded/meta-oe` 不存在**：说明只拉了 poky、未拉 meta-oe。在 **`sources/meta-opentina`** 执行 **`./yocto-init.sh`** 后重试；或 **`./build.sh … yocto build yocto`**（会自动补跑 init）。

---

## OpenWrt rootfs（组件 `openwrt`）

- **源码**：manifest 中的 **`openwrt/openwrt`** → `sources/openwrt`（pin 在 **`openwrt-25.12`** 稳定分支，`clone-depth=1`）。也可设环境变量 **`OPENTINA_OPENWRT_DIR`** 指向本地已有的 OpenWrt 树（如已预热 `build_dir/` 的 fork），跳过 manifest 克隆。
- **配方**：`scripts/recipes.sh` 中的 **`build_openwrt`** / **`clean_openwrt`**；**`OPENTINA_ROOTFS=openwrt`** 时默认组件链使用 **`openwrt`** 替代 **`br2`**。
- **定位**：OpenWrt 只作为 **rootfs 供应商**——boot 链（ATF / U-Boot / 内核 / dtb）全部复用本仓库组件；OpenWrt 自产的内核、kmod 与 per-device 镜像全部丢弃，只消费 target 级 **`openwrt-*-rootfs.tar.gz`**。
- **板级补丁**：`configs/<board>/openwrt-patches/*.patch` 在 defconfig 前按字典序 `git apply` 到 OpenWrt 树（应用前先把补丁涉及文件 reset 回 HEAD，保证可重复执行）。
- **配置**（板级 `config`）：
  - **`OPENWRT_CONFIG`**：板级目录下的 `.config` 种子（如 `openwrt.config`），拷贝后经 `make defconfig` 归一化
  - **`OPENWRT_TARGET`** / **`OPENWRT_SUBTARGET`**：默认 `sunxi` / `cortexa53`
  - **`OPENWRT_ROOTFS_MB`**：`mkfs.ext4` 镜像大小，默认 `2048`（与 `partitions.cfg` root 分区一致）
  - **`OPENWRT_JOBS`**：覆盖 OpenWrt make 并行数（默认 `JOBS`）
- **产物**：`bin/targets/<TGT>/<SUBTGT>/openwrt-*-rootfs.tar.gz` 解包后 `mkfs.ext4 -d` 生成 **`output/<BOARD>/rootfs.ext2`**。解包时会**删除 OpenWrt 自带的 `lib/modules/`**（kmod 按它自己的内核 ABI 编译，如 6.12.x，与 `sources/linux` 不匹配），再拷入 linux 组件 staged 的 `*.ko`。
- **内核**：**`OPENTINA_ROOTFS=openwrt`** 构建 **`linux`** 时合并 **`configs/common/linux-openwrt.fragment`**（tmpfs / unix socket / bridge / nftables 等 builtin，供 procd / netifd / firewall4 使用；kmod 已丢弃，缺特性只能往 fragment 加 builtin）。可用 **`LINUX_OPENWRT_FRAGMENT`** 覆盖路径。
- **示例**：`./build.sh <BOARD> openwrt build`；仅 rootfs：`./build.sh <BOARD> openwrt build openwrt`。首次构建会 bootstrap OpenWrt 自带工具链，耗时较长。
- **注意**：尚未在真实硬件验证（无 A7A 在手）；`radxa_cubie-a7a` 在 OpenWrt 里是 rootfs-only 占位设备（`IMAGES :=`，不产 per-device 镜像），见 `configs/radxa_a7a/openwrt-patches/`。

---

## extlinux 与 U-Boot cmdline

- **`build_bootfs`** 生成的 **`extlinux/extlinux.conf`** 里，**`append`** 由板级 **`EXTLINUX_ROOT`** 与 **`EXTLINUX_CONSOLE`** 拼接（默认 `root=/dev/mmcblk0p4 rw rootwait` + `console=ttyS0,115200 loglevel=9`）。
- 使用 **U-Boot distroboot / extlinux** 时，内核实际拿到的 **cmdline 主要来自这里的 `append`**；请与 U-Boot defconfig 里可能存在的 **`CONFIG_BOOTARGS`** / **`bootcmd`** 保持一致，避免 **root / console 冲突**。若需要更早串口输出，可在 **`EXTLINUX_CONSOLE`** 中加入 SoC 对应的 **`earlycon=...`**（需查阅 UART 基址与驱动）。

---

## `./build.sh` 命令总览

所有子命令前可重复加 **`--docker`**（等价于本次执行启用容器），或单独使用 **`--docker-shell`**（见下文「Docker」）。  
**`--docker` / `--docker-shell` 必须出现在子命令之前**（解析后会被剥掉，再按下面语法处理）。

| 用法 | 说明 |
|------|------|
| `./build.sh` | 无参数：列出板子与 rootfs 类型，并提示常用命令。 |
| `./build.sh targets` 或 `./build.sh list` | 同上列表，仅打印后退出。 |
| `./build.sh init [MANIFEST_XML]` | 按 XML 清单克隆/跳过已有仓库到 `sources/`（默认 `scripts/opentina-manifest.xml`）。 |
| `./build.sh <BOARD_NAME> build [COMPONENT…]` | 构建；未写 `COMPONENT` 时按顺序构建全部组件。 |
| `./build.sh <BOARD_NAME> clean [COMPONENT…]` | 清理对应组件及 `.done` 标记。 |
| `./build.sh <BOARD_NAME> <ROOTFS> build …` | 显式指定 rootfs 后再 `build` / `clean`（见下表）。 |

**第一参数 `BOARD_NAME`**

- 必须与 `configs/*/config` 中的 **`BOARD_NAME=...`** 一致（不是仅目录名；脚本会扫描所有板级配置）。

**`ROOTFS`（可选）**

| ROOTFS | 行为 |
|--------|------|
| （省略） | 等价于 `buildroot`，即 `./build.sh BOARD build` 与 `./build.sh BOARD buildroot build` 相同。 |
| `buildroot` | 命令行里的「发行版槽位」：当前与省略相同，会跑完整组件链（含 **`br2`** Buildroot 根文件系统）。 |
| `ubuntu` | 在 `sources/ubuntu` 中构建 lite rootfs，拷贝为 `output/<BOARD>/rootfs.ext2`（组件名 **`ubuntu`**）。 |
| `debian` | 在 `sources/debian` 中构建 lite rootfs，拷贝为 `output/<BOARD>/rootfs.ext2`（组件名 **`debian`**）。 |
| `yocto` | 在 `sources/meta-opentina` + `sources/yocto` 中 bitbake rootfs，拷贝为 `output/<BOARD>/rootfs.ext2`（组件名 **`yocto`**）。 |
| `openwrt` | 在 `sources/openwrt`（或 `OPENTINA_OPENWRT_DIR`）中构建 rootfs tar，`mkfs.ext4 -d` 转为 `output/<BOARD>/rootfs.ext2`（组件名 **`openwrt`**）。 |

**`COMPONENT`（可选，可多个，空格分隔）**

默认依次构建全部；指定时只处理列出的组件（顺序即执行顺序）：

| 组件 | 含义 |
|------|------|
| `atf` | Trusted Firmware-A（BL31 等） |
| `uboot` | U-Boot（依赖已成功构建的 `atf`） |
| `linux` | Linux 内核与 dtb |
| `br2` | **Buildroot**：在 `sources/buildroot` 中按板级 `BUILDROOT_DEFCONFIG` 生成 `rootfs.ext2`，拷贝到 `output/<BOARD>/rootfs.ext2`（供 `genimage` 使用） |
| `ubuntu` | **Ubuntu rootfs**：在 `sources/ubuntu` 中生成 `ubuntu-rootfs.ext4` 并拷贝为 `rootfs.ext2`（`OPENTINA_ROOTFS=ubuntu` 时替代 `br2`） |
| `debian` | **Debian rootfs**：在 `sources/debian/out/` 中取最新 `.ext4` 并拷贝为 `rootfs.ext2`（`OPENTINA_ROOTFS=debian` 时替代 `br2`） |
| `yocto` | **Yocto rootfs**：bitbake **`opentina-image-minimal`** / **`-qt`**，ext4 拷贝为 `rootfs.ext2`（`OPENTINA_ROOTFS=yocto` 时替代 `br2`） |
| `openwrt` | **OpenWrt rootfs**：取 `bin/targets/…/openwrt-*-rootfs.tar.gz` 经 `mkfs.ext4 -d` 转为 `rootfs.ext2`（`OPENTINA_ROOTFS=openwrt` 时替代 `br2`） |
| `bootfs` | 启动用 FAT 目录树（依赖 `linux`） |
| `image` | `genimage` 生成 `sdcard.img` 等（依赖 `bootfs`、`uboot`，以及 `br2` / `ubuntu` / `debian` / `yocto` / `openwrt`） |

依赖不满足时会报错退出（要求 `output/<BOARD>/.done.<依赖组件>` 存在）。

**并行数**

- 环境变量 **`JOBS`**：未设置时使用 `nproc`，并写入 `MAKEFLAGS=-j$JOBS`。

---

## Docker（Ubuntu 24.04）

默认在**宿主机**执行；需要与 Dockerfile 一致的环境时，任选其一进入容器再跑同一套参数：

```bash
# 单次命令在容器内执行
./build.sh --docker radxa_a7a build

# 整个 shell 会话都在容器里构建
export OPENTINA_DOCKER=1
./build.sh radxa_a7a clean
./build.sh radxa_a7a build

# 只打开容器里的交互 shell（仓库已 bind-mount 到相同路径）
./build.sh --docker-shell
```

| 变量 / 参数 | 说明 |
|-------------|------|
| `OPENTINA_DOCKER=1` | 本次进程在宿主机上时，若存在 `docker` 命令则 `exec` 进默认镜像再执行 `build.sh`。设为 `0` 可关闭（在曾 `export OPENTINA_DOCKER=1` 的 shell 里恢复宿主机构建）。 |
| `--docker` | 与上类似，仅作用于**当前命令**（可写多次，效果同开）。 |
| `--docker-shell` | 不进 `build.sh` 子命令，直接进入镜像内 `bash -il`。 |
| `OPENTINA_SKIP_DOCKER=1` | 强制宿主机：即使环境里带了 `OPENTINA_DOCKER=1` 也不进容器。 |
| `OPENTINA_DOCKER_IMAGE` | 默认 `opentina-buildenv:24.04`；不存在时由 `scripts/docker-exec.sh` 对 `docker/Dockerfile` 执行 `docker build`。 |
| `OPENTINA_DOCKER_HOSTNAME` | 容器主机名（提示符里 `@` 之后），默认 **`opentina`**。 |

容器内会设置 **`OPENTINA_IN_DOCKER=1`**，避免重复套 Docker。  
需要 **`git@` 克隆**时，宿主机上建议配置 SSH agent 或挂载密钥；`docker-exec.sh` 会尝试传递 `SSH_AUTH_SOCK` 与只读挂载 `~/.ssh`。

---

## `./build.sh init` 与清单 XML

- 实际调用：`scripts/repo_clone.sh --gitclone <manifest>`。
- 默认清单：`scripts/opentina-manifest.xml`（`<remote>`、`<default revision>`、`<project>`）。
- **`clone-depth`**：可在 `<manifest>` 或单个 `<project>` 上写正整数做浅克隆；不写或写 `full` / `0` 等为完整历史（详见 manifest 注释）。
- 环境变量 **`OPENTINA_REMOTE_FETCH`**：若设置，覆盖 manifest 里所有 `<remote fetch="...">`（便于切换 HTTPS / SSH 基地址）。
- **`OPENTINA_SOURCES_DIR`**：检出根目录，默认 `$OPENTINA_BUILD_ROOT/sources`。
- **`OPENTINA_BUILD_ROOT`**：构建仓库根，一般无需改。

同步已存在仓库（非 init）：可直接执行：

```bash
./scripts/repo_clone.sh --sync ./scripts/opentina-manifest.xml
```

---

## 目录与产物

| 路径 | 说明 |
|------|------|
| `sources/` | `trusted-firmware-a`、`u-boot`、`linux`、`buildroot`、`ubuntu`、`debian`、`meta-opentina`、`yocto/`（Yocto 工作区，由 init 生成）、`awbin` 等（由 manifest 决定；根目录 `.gitignore` 已忽略） |
| `output/<BOARD_NAME>/` | 内核、dtb、`rootfs.ext2`、`u-boot.fex`、`boot.img`、`sdcard.img`、`.done.*` 等 |
| `configs/<板级目录>/` | `config`、`partitions.cfg`（`BOARD_NAME` 可与目录名不同） |
| `scripts/` | `recipes.sh`、`repo_clone.sh`、`docker-exec.sh`、`opentina-boards.sh` 等 |
| `docker/Dockerfile` | 默认构建环境镜像定义 |

---

## 板级 `configs/*/config` 常用变量

在对应板子的 `config` 中可设置（示例见 `configs/radxa_a7a/config`）：

| 变量 | 说明 |
|------|------|
| `BOARD_NAME` | 与命令行第一个参数一致，用于 awbin 路径、`output/` 子目录名等 |
| `PRETTY_NAME` | 仅用于 `./build.sh targets` 展示 |
| `OPENTINA_CROSS_COMPILE` | 默认 `aarch64-linux-gnu-`；TF-A、U-Boot、Linux 共用此前缀（与 `docker` 镜像内工具链一致） |
| `FDT_NAME` | 拷贝到 `output/` 的设备树文件名 |
| `UBOOT_CONFIG` | `make …_defconfig` 名 |
| `LINUX_CONFIG` | 内核 defconfig 名 |
| `PARTITION_CONFIG` | `genimage` 配置文件路径（一般为 `$OPENTINA_BUILD_ROOT/configs/<目录>/partitions.cfg`） |
| `BUILDROOT_DEFCONFIG` | Buildroot 片段 defconfig 文件名（位于同一板级目录，默认 `br2_opentina.defconfig`） |
| `EXTLINUX_ROOT` | 写入 `extlinux.conf` 的 **root=** 等（默认 `root=/dev/mmcblk0p4 rw rootwait`，需与 GPT 根分区序号一致） |
| `EXTLINUX_CONSOLE` | 写入 `extlinux.conf` 的 **console / loglevel / earlycon** 等 |

---

## 获取帮助

```bash
./build.sh this-is-not-a-board
# 或省略必填参数，触发 usage
```

会打印内置用法摘要（与本文对应；以脚本为准）。

---

## 许可

以仓库上层或本目录已有 `LICENSE` / 说明为准；厂商二进制（如 `awbin`）适用其自带条款。
