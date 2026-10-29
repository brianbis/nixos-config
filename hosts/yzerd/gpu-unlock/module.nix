# gpu-unlock (github:Zagitta/gpu-unlock, v2.0.0) built as an out-of-tree kernel
# module for THIS configuration's kernel package — the same contract hardware.nix
# relies on for nvidia-open, whose .drv shows
#   KBUILD_OUTPUT=${kernel.dev}/lib/modules/${kernel.modDirVersion}/build
#   MODLIB=$(out)/lib/modules/6.18.56
# Building against config.boot.kernelPackages.kernel (not pkgs.linuxPackages.kernel)
# keeps the kabi and the randstruct seed identical to the booted kernel, which is
# what lets gpu_unlock touch struct pci_dev members at all.
{
  lib,
  stdenvNoCC,
  kmod,
  kernel,
  src,
}:

let
  version = lib.removeSuffix "\n" (builtins.readFile (src + "/VERSION"));
  modDir = "${kernel.dev}/lib/modules/${kernel.modDirVersion}";
in
stdenvNoCC.mkDerivation (finalAttrs: {
  name = "gpu-unlock-${version}-kernel-${kernel.modDirVersion}";

  inherit src version;

  # kbuild's M= mechanics (read off <kernel source>/Makefile:170-250 of this
  # kernel): objtree := realpath(KBUILD_OUTPUT) supplies include/config/auto.conf,
  # scripts/module.lds and Module.symvers — read-only store paths are fine for
  # that — while output := $(KBUILD_EXTMOD) whenever CURDIR matches objtree or
  # srctree, so the sub-make runs IN THE MODULE DIR: every .o/.ko, $(obj)/gpu_unlock.mod
  # (scripts/Makefile.build:295 `$(obj)/%.mod: FORCE` → `if_changed,mod` →
  # `… > $@`) and the cc-option probes' `mkdir .tmp_$$` (scripts/Kconfig.include:28)
  # land there. That is why $work is the only writable tree, and why it needs an
  # explicit chmod: the gpu-unlock input dir is 0555 in the store, cp preserves
  # the mode bits, and the sandbox's uid then gets "mkdir: cannot create directory
  # '.tmp_171': Permission denied" plus "sh: line 1: gpu_unlock.mod: Permission
  # denied" (a failed redirect) on every target.
  #
  # The compiler comes from kernel.stdenv.cc — the same cc-wrapper the kernel
  # itself was built with (kernel.depsBuildBuild = [ kernel.stdenv.cc ]) — so
  # kbuild's $(CC)/$(HOSTCC) resolve through it and the wrapper exports AS/LD.
  buildPhase = ''
    mkdir -p "$out/lib/modules/${kernel.modDirVersion}/kernel/drivers/video"
    work=/tmp/gpu-unlock-mod-build
    rm -rf "$work"
    mkdir -p "$work"
    cp -rP --preserve=mode "$src/kernel/gpu_unlock/." "$work"
    chmod -R u+w "$work"
    kb="${modDir}/build"
    test -f "$kb/include/config/auto.conf"
    # arch/x86/Makefile's `ifeq ($(CONFIG_X86_KERNEL_IBT),y)` CFI flags apply only
    # to in-tree targets; an external module of a CET kernel must add them itself
    # or asm/ibt.h's nocf_check attributes trip -Werror=attributes.
    cfi=""
    if grep -q "^CONFIG_X86_KERNEL_IBT=y" "$kb/include/config/auto.conf"; then
      cfi="-fcf-protection=branch"
    fi
    # CONFIG_DEBUG_INFO_BTF_MODULES=y adds a pahole/resolve_btfids pass to
    # Makefile.modfinal; dwarves is not in this derivation, and the kernel sets
    # CONFIG_MODULE_ALLOW_BTF_MISMATCH=y, so the module loads without BTF.
    btf=""
    if grep -q "^CONFIG_DEBUG_INFO_BTF_MODULES=y" "$kb/include/config/auto.conf"; then
      btf="CONFIG_DEBUG_INFO_BTF_MODULES="
    fi
    make -C "$kb" M="$work" ARCH=x86_64 CROSS_COMPILE= IGNORE_PREEMPT_RT_PRESENCE=1 TARGET_ARCH=x86_64 KCFLAGS="-Werror $cfi" $btf modules
    test -f "$work/gpu_unlock.ko"
  '';

  # gpu-unlock ships a top-level Makefile whose `install` target builds a
  # dpkg/rpm package ("Unsupported distribution: unknown." in this build), which
  # is what stdenv's default installPhase would run. Install the .ko ourselves.
  installPhase = ''
    install -Dm644 /tmp/gpu-unlock-mod-build/gpu_unlock.ko \
      "$out/lib/modules/${kernel.modDirVersion}/kernel/drivers/video/gpu_unlock.ko"
  '';

  # The module name is what stage-1 modprobe resolves in the initrd; assert it.
  postInstall = ''
    test "$(modinfo -F name "$out/lib/modules/${kernel.modDirVersion}/kernel/drivers/video/gpu_unlock.ko")" = gpu_unlock
    test "$(modinfo -F modversion "$out/lib/modules/${kernel.modDirVersion}/kernel/drivers/video/gpu_unlock.ko")" = "${version}"
  '';

  # kernel.stdenv.cc is the exact cc-wrapper the kernel itself was built with
  # (kernel.depsBuildBuild = [ kernel.stdenv.cc ]), so kbuild's $(CC)/$(HOSTCC)
  # resolve through it and the wrapper exports AS/LD for the binutils it drags in
  # — proved needed on the box: without a real cc, kbuild printed
  # "You are using:" empty and died on `sh: line 1: gcc: command not found`.
  nativeBuildInputs = [ kmod kernel.stdenv.cc ];

})
