# nabu Android 16 kernel build

The default entry point is `nabu_defconfig`. The scripts do not flash, reboot,
change swap, or touch a connected device.

```sh
JOBS=4 ./bk_build/build.sh
```

The script fixes AOSP Clang 20 r547379, LLVM binutils, and pahole v1.25. It
builds the kernel and then creates and validates the AnyKernel package from
`bk_build/anykernel`. `KERNEL_DIR`, `OUT_DIR`, `DEFCONFIG`, `CLANG_DIR`,
`GCC64_DIR`, `GCC32_DIR`, and `PAHOLE` can be overridden. The local defaults
match the maintainer workstation. `nabu-perf_defconfig` is not a supported
default because it does not select `CONFIG_MACH_XIAOMI_NABU`.

GitHub Actions uses the same script with pinned toolchains. The
`Build and release nabu kernel` workflow is started manually and publishes
the validated ZIP plus its SHA256 file to GitHub Releases after a successful
build. CI sets `DISABLE_LTO_CACHE=1` because the ThinLTO cache is disposable
and exceeds the hosted runner disk budget.

The packaged `dtb` follows the HyperOS vendor_boot order: `sm8150.dtb`,
`sm8150p.dtb`, `sm8150p-v2.dtb`, and `sm8150-v2.dtb`. The package targets
`nabu` and handles boot and vendor_boot separately. Restore the boot image
matching the installed system before installing from a flashed PBRP image;
the installer rejects a boot image carrying `twrpfastboot=1`.
