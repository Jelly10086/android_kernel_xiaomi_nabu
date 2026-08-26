#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -n "${KERNEL_DIR:-}" ]; then
  KERNEL_DIR=$(CDPATH= cd -- "$KERNEL_DIR" && pwd)
else
  KERNEL_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
fi
ARCH=${ARCH:-arm64}
DEFCONFIG=${DEFCONFIG:-nabu_defconfig}
OUT_DIR=${OUT_DIR:-/home/rinnrei/Project/uwuAP-temp/out/nabu-4.14.336-b3k1}
JOBS=${JOBS:-4}
CLANG_DIR=${CLANG_DIR:-/home/rinnrei/Project/uwuAOSP/prebuilts/clang/host/linux-x86/clang-r547379}
GCC64_DIR=${GCC64_DIR:-/home/rinnrei/Project/uwuAP-temp/toolchains/nabu/gcc64}
GCC32_DIR=${GCC32_DIR:-/home/rinnrei/Project/uwuAP-temp/toolchains/nabu/gcc32}
PAHOLE=${PAHOLE:-/home/rinnrei/Project/uwuAOSP/prebuilts/kernel-build-tools/linux-x86/bin/pahole}
PAHOLE_FLAGS=${PAHOLE_FLAGS:-"--skip_encoding_btf_decl_tag --skip_encoding_btf_type_tag --skip_encoding_btf_enum64"}
DISABLE_LTO_CACHE=${DISABLE_LTO_CACHE:-1}
CCACHE=${CCACHE:-}
CROSS_COMPILE=${CROSS_COMPILE:-aarch64-linux-androidkernel-}
CROSS_COMPILE_ARM32=${CROSS_COMPILE_ARM32:-arm-linux-androideabi-}
CLANG_TRIPLE=${CLANG_TRIPLE:-aarch64-linux-gnu-}
FRAGMENT=${FRAGMENT:-$SCRIPT_DIR/configs/nabu-17.0.config}

case "$JOBS" in ''|*[!0-9]*) echo "JOBS must be a positive integer" >&2; exit 2 ;; esac
[ "$JOBS" -gt 0 ] || { echo "JOBS must be greater than zero" >&2; exit 2; }
case "$DISABLE_LTO_CACHE" in 0|1) ;; *) echo "DISABLE_LTO_CACHE must be 0 or 1" >&2; exit 2 ;; esac
[ -f "$KERNEL_DIR/arch/$ARCH/configs/$DEFCONFIG" ] || {
  echo "defconfig not found: $KERNEL_DIR/arch/$ARCH/configs/$DEFCONFIG" >&2; exit 2;
}
[ -f "$FRAGMENT" ] || { echo "config fragment not found: $FRAGMENT" >&2; exit 2; }

mkdir -p "$OUT_DIR"
OUT_DIR=$(CDPATH= cd -- "$OUT_DIR" && pwd)
for tool in clang ld.lld llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-strip; do
  [ -x "$CLANG_DIR/bin/$tool" ] || { echo "$tool not found under $CLANG_DIR/bin" >&2; exit 2; }
done
[ -x "$PAHOLE" ] || { echo "pahole not found: $PAHOLE" >&2; exit 2; }
[ "$("$PAHOLE" --version)" = "v1.25" ] || { echo "pahole v1.25 is required" >&2; exit 2; }
"$CLANG_DIR/bin/clang" --version | head -1 | grep -F 'r547379' >/dev/null || {
  echo "AOSP Clang r547379 is required" >&2; exit 2;
}
CC="$CLANG_DIR/bin/clang"
if [ -n "$CCACHE" ]; then
  command -v "$CCACHE" >/dev/null 2>&1 || {
    echo "ccache not found: $CCACHE" >&2; exit 2;
  }
  CC="$CCACHE $CC"
fi
PATH="$CLANG_DIR/bin:$PATH"
if [ -n "$GCC64_DIR" ]; then
  [ -d "$GCC64_DIR/bin" ] || {
    echo "64-bit GNU binutils not found: $GCC64_DIR/bin" >&2; exit 2;
  }
  PATH="$GCC64_DIR/bin:$PATH"
fi
if [ -n "$GCC32_DIR" ]; then
  [ -d "$GCC32_DIR/bin" ] || {
    echo "32-bit GNU binutils not found: $GCC32_DIR/bin" >&2; exit 2;
  }
  PATH="$GCC32_DIR/bin:$PATH"
fi
export PATH

make_kernel()
{
  make -C "$KERNEL_DIR" \
    ARCH="$ARCH" O="$OUT_DIR" \
    CC="$CC" LD="$CLANG_DIR/bin/ld.lld" \
    AR="$CLANG_DIR/bin/llvm-ar" NM="$CLANG_DIR/bin/llvm-nm" \
    OBJCOPY="$CLANG_DIR/bin/llvm-objcopy" \
    OBJDUMP="$CLANG_DIR/bin/llvm-objdump" \
    STRIP="$CLANG_DIR/bin/llvm-strip" \
    CLANG_TRIPLE="$CLANG_TRIPLE" \
    CROSS_COMPILE="$CROSS_COMPILE" \
    CROSS_COMPILE_ARM32="$CROSS_COMPILE_ARM32" \
    PAHOLE="$PAHOLE" PAHOLE_FLAGS="$PAHOLE_FLAGS" \
    DISABLE_LTO_CACHE="$DISABLE_LTO_CACHE" "$@"
}

stage()
{
  printf '\n[%s] %s\n' "$1" "$2"
}

stage "Config" "内核目录：$KERNEL_DIR"
printf '输出目录：%s\n配置文件：%s\n并行任务：%s\n' \
  "$OUT_DIR" "$DEFCONFIG" "$JOBS"
printf 'ThinLTO 磁盘缓存：%s\n' "$([ "$DISABLE_LTO_CACHE" = 1 ] && echo 关闭 || echo 开启)"
printf 'ccache：%s\n' "$([ -n "$CCACHE" ] && echo 开启 || echo 关闭)"

# Merge the feature fragment after nabu_defconfig, then resolve dependencies.
stage "Config" "生成内核配置"
make_kernel "$DEFCONFIG"
KCONFIG_CONFIG="$OUT_DIR/.config" "$KERNEL_DIR/scripts/kconfig/merge_config.sh" -m \
  "$OUT_DIR/.config" "$FRAGMENT"
make_kernel olddefconfig
stage "Check" "核对必要选项"
for symbol in MACH_XIAOMI_NABU BPF BPF_SYSCALL BPF_JIT BPF_JIT_ALWAYS_ON \
  BPF_EVENTS CGROUPS MEMCG CGROUP_SCHED CGROUP_FREEZER CGROUP_CPUACCT \
  CGROUP_BPF CGROUP_DEVICE CGROUP_PIDS CGROUP_NET_PRIO CPUSETS PSI \
  BLK_CGROUP CGROUP_WRITEBACK FAIR_GROUP_SCHED \
  SYSCTL SYSVIPC POSIX_MQUEUE NAMESPACES UTS_NS IPC_NS USER_NS PID_NS NET_NS \
  SECCOMP SECCOMP_FILTER DEVTMPFS INITRAMFS_IGNORE_SKIP_FLAG UNICODE \
  INET IPV6 SOCK_CGROUP_DATA NET_CLS_BPF NET_CLS_ACT \
  OVERLAY_FS TMPFS_POSIX_ACL TMPFS_XATTR \
  FW_LOADER FW_LOADER_USER_HELPER VETH BRIDGE BRIDGE_NETFILTER \
  NETFILTER NETFILTER_ADVANCED NF_CONNTRACK NF_CONNTRACK_PROCFS \
  NF_CT_NETLINK NF_NAT \
  NF_NAT_REDIRECT NF_TABLES IP_NF_IPTABLES IP_NF_FILTER IP_NF_NAT \
  IP_NF_TARGET_MASQUERADE NETFILTER_XT_TARGET_TCPMSS \
  NETFILTER_XT_MATCH_ADDRTYPE IP_ADVANCED_ROUTER IP_MULTIPLE_TABLES \
  PREEMPT__LL PREEMPT CPU_FREQ_GOV_SCHEDUTIL \
  CC_OPTIMIZE_FOR_SIZE DEBUG_INFO \
  LRU_GEN ZRAM ZRAM_WRITEBACK \
  DEBUG_INFO_DWARF4 DEBUG_INFO_BTF DEBUG_FS DEBUG_KERNEL DYNAMIC_DEBUG \
  KALLSYMS KALLSYMS_ALL FRAME_POINTER \
  PRINTK_TIME PSTORE \
  PSTORE_ZLIB_COMPRESS PSTORE_CONSOLE PSTORE_PMSG PSTORE_RAM PSTORE_FTRACE \
  MAGIC_SYSRQ SCHEDSTATS LOCKUP_DETECTOR SOFTLOCKUP_DETECTOR \
  DETECT_HUNG_TASK DEBUG_OBJECTS DEBUG_VM \
  DEBUG_VIRTUAL DEBUG_MEMORY_INIT DEBUG_PER_CPU_MAPS \
  DEBUG_SPINLOCK DEBUG_MUTEXES DEBUG_ATOMIC_SLEEP DEBUG_LIST DEBUG_NOTIFIERS \
  FUNCTION_TRACER FUNCTION_GRAPH_TRACER IRQSOFF_TRACER PREEMPT_TRACER \
  SCHED_TRACER FTRACE_SYSCALLS STACK_TRACER \
  KSU KSU_MANUAL_HOOK; do
  grep -qx "CONFIG_$symbol=y" "$OUT_DIR/.config" || {
    echo "required config is not enabled: CONFIG_$symbol" >&2; exit 1;
  }
done
for symbol in DEBUG_INFO_REDUCED DEBUG_INFO_SPLIT \
  CC_OPTIMIZE_FOR_PERFORMANCE SCHED_WALT IRQ_TIME_ACCOUNTING \
  PREEMPT_RT_FULL PREEMPT_RTB PREEMPT_RT_BASE RCU_BOOST; do
  if grep -q "^CONFIG_$symbol=" "$OUT_DIR/.config"; then
    echo "required config is not disabled: CONFIG_$symbol" >&2; exit 1
  fi
done
grep -q '^# CONFIG_PANIC_ON_OOPS is not set$' "$OUT_DIR/.config" || {
  echo "required config is not disabled: CONFIG_PANIC_ON_OOPS" >&2; exit 1;
}
grep -qx '# CONFIG_LRU_GEN_ENABLED is not set' "$OUT_DIR/.config" || {
  echo "required config is not disabled: CONFIG_LRU_GEN_ENABLED" >&2; exit 1;
}
grep -qx 'CONFIG_LOCALVERSION=""' "$OUT_DIR/.config" || {
  echo "kernel local version is incorrect" >&2; exit 1;
}
grep -qx 'CONFIG_DEFAULT_NOOP=y' "$OUT_DIR/.config" || {
  echo "UFS default I/O scheduler is not noop" >&2; exit 1;
}
grep -qx 'CONFIG_DEFAULT_IOSCHED="noop"' "$OUT_DIR/.config" || {
  echo "default I/O scheduler name is not noop" >&2; exit 1;
}
grep -qx 'CONFIG_LOG_BUF_SHIFT=21' "$OUT_DIR/.config" || {
  echo "required config is not set: CONFIG_LOG_BUF_SHIFT=21" >&2; exit 1;
}
grep -qx 'CONFIG_PRINTK_SAFE_LOG_BUF_SHIFT=13' "$OUT_DIR/.config" || {
  echo "required config is not set: CONFIG_PRINTK_SAFE_LOG_BUF_SHIFT=13" >&2; exit 1;
}
grep -qx 'CONFIG_PANIC_TIMEOUT=-1' "$OUT_DIR/.config" || {
  echo "required config is not set: CONFIG_PANIC_TIMEOUT=-1" >&2; exit 1;
}
grep -qx 'CONFIG_CMDLINE=""' "$OUT_DIR/.config" || {
  echo "legacy ramoops command line is still enabled" >&2; exit 1;
}
cp "$OUT_DIR/.config" "$OUT_DIR/nabu-17.0.config"

# Build generated-header owners before the parallel object batch.
stage "Build" "编译内核对象"
make_kernel init/version.o
make_kernel -j"$JOBS" security/selinux/
make_kernel -j"$JOBS" \
  kernel/bpf/syscall.o kernel/bpf/verifier.o kernel/bpf/btf.o \
  kernel/bpf/arraymap.o kernel/bpf/hashtab.o kernel/bpf/ringbuf.o \
  kernel/bpf/xskmap_compat.o net/core/bpf_sk_storage.o \
  net/core/filter.o kernel/bpf/cgroup.o net/ipv4/udp.o net/ipv6/udp.o \
  drivers/devfreq/bimc-bwmon.o \
  drivers/extcon/extcon.o \
  drivers/kernelsu/ksu.o \
  arch/arm64/kernel/setup.o arch/arm64/kernel/cpu_errata.o \
  arch/arm64/net/bpf_jit_comp.o fs/pstore/ram.o fs/pstore/platform.o \
  kernel/printk/printk.o kernel/sys.o mm/oom_kill.o \
  kernel/fork.o kernel/sched/core.o kernel/sched/fair.o \
  kernel/futex.o kernel/irq/handle.o kernel/irq/manage.o kernel/kthread.o \
  kernel/ptrace.o kernel/smp.o kernel/workqueue.o \
  kernel/cgroup/cgroup.o kernel/cgroup/pids.o security/device_cgroup.o \
  kernel/pid_namespace.o kernel/user_namespace.o ipc/namespace.o \
  drivers/net/veth.o fs/overlayfs/ \
  drivers/block/zram/zram_drv.o mm/zsmalloc.o \
  mm/maccess.o mm/memcontrol.o \
  drivers/android/binder.o drivers/staging/android/ion/ion.o \
  drivers/scsi/ufs/ufshcd.o drivers/scsi/ufs/ufs-qcom.o \
  drivers/usb/dwc3/core.o drivers/usb/dwc3/gadget.o \
  drivers/usb/gadget/configfs.o \
  drivers/usb/gadget/function/f_accessory.o \
  drivers/usb/gadget/function/f_fs.o \
  drivers/usb/gadget/function/rndis.o drivers/usb/host/xhci.o \
  fs/f2fs/ fs/pstore/ \
  net/core/dev.o net/core/skbuff.o net/ipv4/inet_connection_sock.o \
  net/ipv6/ip6_output.o net/netfilter/nf_conntrack_irc.o \
  sound/core/control.o \
  drivers/clk/qcom/clk-cpu-osm.o \
  drivers/clocksource/arm_arch_timer.o net/wireguard/ \
  drivers/mailbox/mailbox.o \
  drivers/md/dm-verity-target.o \
  drivers/soc/qcom/early_random.o \
  kernel/events/core.o kernel/trace/trace.o kernel/trace/trace_events.o \
  kernel/trace/trace_output.o

# Re-enter make after compiling overlays so DTBO_OBJS is evaluated again.
stage "Build" "编译Image.gz+设备树"
make_kernel -j"$JOBS" Image.gz dtbs
stage "Build" "生成dtbo.img"
make_kernel -j"$JOBS" dtbo.img

stage "Check" "校验Image / BTF / DTB / DTBO"
BOOT="$OUT_DIR/arch/$ARCH/boot"
DTB_ROOT="$BOOT/dts/qcom"
mkdir -p "$OUT_DIR/artifacts"
gzip -t "$BOOT/Image.gz"
image_magic=$(gzip -dc "$BOOT/Image.gz" | dd bs=1 skip=56 count=4 2>/dev/null | \
  od -An -tx1 | tr -d ' \n')
[ "$image_magic" = "41524d64" ] || {
  echo "invalid arm64 Image magic: $image_magic" >&2; exit 1;
}
cp "$BOOT/Image.gz" "$OUT_DIR/artifacts/Image.gz"
arm64_image_size=$(od -An -tu8 -j16 -N8 "$BOOT/Image" | tr -d ' \n')
[ "$arm64_image_size" -le 67108864 ] || {
  echo "arm64 Image exceeds nabu 64 MiB boot window: $arm64_image_size bytes" >&2
  exit 1
}
for name in sm8150-v2 sm8150 sm8150p-v2 sm8150p; do
  [ -f "$DTB_ROOT/$name.dtb" ] || { echo "missing $name.dtb" >&2; exit 1; }
  dtb_magic=$(dd if="$DTB_ROOT/$name.dtb" bs=1 count=4 2>/dev/null | \
    od -An -tx1 | tr -d ' \n')
  [ "$dtb_magic" = "d00dfeed" ] || {
    echo "invalid FDT magic: $name.dtb" >&2; exit 1;
  }
done
NABU_DTBO="$DTB_ROOT/nabu-sm8150-overlay.dtbo"
[ -f "$NABU_DTBO" ] || { echo "missing nabu-sm8150-overlay.dtbo" >&2; exit 1; }
for panel in dsi_k81_42_02_0a_dual_cphy_vid_display \
  dsi_k81_35_02_0b_dual_cphy_vid_display; do
  strings "$NABU_DTBO" | grep -Fx "$panel" >/dev/null || {
    echo "missing Pad 5 Pro panel in nabu overlay: $panel" >&2; exit 1;
  }
done
# Match the AOSP nabu vendor_boot DTB order:
# sm8150-v2-xiaomi, sm8150-xiaomi, sm8150p-v2-xiaomi, sm8150p-xiaomi.
cat "$DTB_ROOT/sm8150-v2.dtb" "$DTB_ROOT/sm8150.dtb" \
  "$DTB_ROOT/sm8150p-v2.dtb" "$DTB_ROOT/sm8150p.dtb" > "$OUT_DIR/artifacts/dtb"
cp "$BOOT/dtbo.img" "$OUT_DIR/artifacts/dtbo.img"
python3 "$KERNEL_DIR/scripts/dtc/libfdt/mkdtboimg.py" \
  dump "$OUT_DIR/artifacts/dtbo.img" > "$OUT_DIR/artifacts/dtbo-dump.txt"
[ -s "$OUT_DIR/artifacts/dtbo-dump.txt" ] || {
  echo "dtbo.img metadata dump is empty" >&2; exit 1;
}
[ -f "$OUT_DIR/vmlinux" ] || { echo "vmlinux is missing" >&2; exit 1; }
"$CLANG_DIR/bin/llvm-objdump" -h "$OUT_DIR/vmlinux" | grep -F '.BTF' >/dev/null || {
  echo "vmlinux has no .BTF section" >&2; exit 1;
}
"$PAHOLE" -F btf -C task_struct "$OUT_DIR/vmlinux" > \
  "$OUT_DIR/artifacts/btf-task_struct.txt"
grep -Eq '(^|[[:space:]])pid[[:space:]]*;' \
  "$OUT_DIR/artifacts/btf-task_struct.txt" || {
  echo "BTF task_struct::pid is missing" >&2; exit 1;
}
kernel_release=$(make_kernel -s kernelrelease)
[ "$kernel_release" = "4.14.336_bk-Kernel_17.0-b3k1" ] || {
  echo "unexpected kernel release: $kernel_release" >&2; exit 1;
}

stage "Generate" "生成bk-ZRAM_Tool"
"$CLANG_DIR/bin/clang" --target=aarch64-linux-android \
  -Oz -ffreestanding -fno-builtin -fno-stack-protector \
  -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-pie \
  -nostdlib -static -fuse-ld=lld -Wl,-e,_start -Wl,--build-id=none \
  -Wl,-z,max-page-size=4096 \
  "$SCRIPT_DIR/tools/bk-zram-setup.c" \
  -o "$OUT_DIR/artifacts/bk-zram-setup"
"$CLANG_DIR/bin/llvm-objdump" -f "$OUT_DIR/artifacts/bk-zram-setup" | \
  grep -F 'architecture: aarch64' >/dev/null || {
    echo "invalid zram helper architecture" >&2; exit 1;
  }
chmod 0755 "$OUT_DIR/artifacts/bk-zram-setup"
"$CLANG_DIR/bin/clang" --target=aarch64-linux-android \
  -Oz -ffreestanding -fno-builtin -fno-stack-protector \
  -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-pie \
  -nostdlib -static -fuse-ld=lld -Wl,-e,_start -Wl,--build-id=none \
  -Wl,-z,max-page-size=4096 \
  "$SCRIPT_DIR/tools/bk-keyboard-monitor.c" \
  -o "$OUT_DIR/artifacts/bk-keyboard-monitor"
"$CLANG_DIR/bin/llvm-objdump" -f "$OUT_DIR/artifacts/bk-keyboard-monitor" | \
  grep -F 'architecture: aarch64' >/dev/null || {
    echo "invalid keyboard monitor architecture" >&2; exit 1;
  }
chmod 0755 "$OUT_DIR/artifacts/bk-keyboard-monitor"

dirty_diff_sha=$(git -C "$KERNEL_DIR" diff --binary HEAD -- | sha256sum | awk '{print $1}')
ksu_tree_sha=$(
  cd "$KERNEL_DIR/drivers/kernelsu"
  find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | awk '{print $1}'
)
anykernel_template_sha=$(
  cd "$SCRIPT_DIR"
  {
    sha256sum anykernel.sh
    find anykernel -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum
  } | sha256sum | awk '{print $1}'
)
git -C "$KERNEL_DIR" ls-files --others --exclude-standard > \
  "$OUT_DIR/artifacts/untracked-sources.txt"
{
  echo "ARCH=$ARCH"
  echo "DEFCONFIG=$DEFCONFIG"
  echo "JOBS=$JOBS"
  echo "DISABLE_LTO_CACHE=$DISABLE_LTO_CACHE"
  echo "DTB_ORDER=sm8150,sm8150p,sm8150p-v2,sm8150-v2"
  echo "ARM64_IMAGE_SIZE=$arm64_image_size"
  echo "KERNEL_COMMIT=$(git -C "$KERNEL_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "KERNEL_DIRTY_DIFF_SHA256=$dirty_diff_sha"
  echo "ANDROID_STABLE_COMMIT=014241ad77dda0eafbdf671d5b8e86917d8ec97e"
  echo "QUALCOMM_REFERENCE_COMMIT=d1966c80dcfcabe6058eba05ded94a9af967760f"
  echo "KERNELSU_COMMIT=648e5988cf421172769f80ce07f86331b548c053"
  echo "DROIDSPACES_COMMIT=7412f6fb732fe7f5e3dc6ac0848d82ef9ff98acf"
  echo "KERNELSU_TREE_SHA256=$ksu_tree_sha"
  echo "ANYKERNEL_TEMPLATE_SHA256=$anykernel_template_sha"
  echo "ZRAM_SETUP_SHA256=$(sha256sum "$OUT_DIR/artifacts/bk-zram-setup" | awk '{print $1}')"
  echo "KEYBOARD_MONITOR_SHA256=$(sha256sum "$OUT_DIR/artifacts/bk-keyboard-monitor" | awk '{print $1}')"
  echo "CLANG=$CLANG_DIR/bin/clang"
  "$CLANG_DIR/bin/clang" --version | head -1
  if [ -n "$CCACHE" ]; then
    echo "CCACHE=$(command -v "$CCACHE")"
    "$CCACHE" --version | head -1
  else
    echo "CCACHE=disabled"
  fi
  echo "PAHOLE=$PAHOLE"
  "$PAHOLE" --version
  echo "UNTRACKED_SOURCE_LIST=untracked-sources.txt"
} > "$OUT_DIR/artifacts/build-info.txt"
cp "$OUT_DIR/nabu-17.0.config" "$OUT_DIR/artifacts/nabu-17.0.config"
(cd "$OUT_DIR/artifacts" && \
  sha256sum Image.gz dtb dtbo.img dtbo-dump.txt btf-task_struct.txt \
    build-info.txt nabu-17.0.config untracked-sources.txt bk-zram-setup \
    bk-keyboard-monitor) > \
  "$OUT_DIR/artifacts/SHA256SUMS"
stage "Package" "打包AnyKernel3包"
package_path=$(KERNEL_DIR="$KERNEL_DIR" OUT_DIR="$OUT_DIR" \
  KERNEL_RELEASE="$kernel_release" "$SCRIPT_DIR/pack.sh")
package_sha=$(sha256sum "$package_path" | awk '{print $1}')
stage "Done" "构建与打包通过"
printf '[Artifact] 内核版本 : %s\n' "$kernel_release"
printf '[Artifact] 产物目录 : %s/artifacts\n' "$OUT_DIR"
printf '[Artifact] 安装包   : %s\n' "$package_path"
printf '[Artifact] SHA256   : %s\n' "$package_sha"
