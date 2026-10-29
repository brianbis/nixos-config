# gpu-unlock's firmware blobs, rebuilt from the two pinned NVIDIA inputs with
# upstream's own extractors — the same recipe its debian packaging runs
# (Makefile `firmware:` = untar NVIDIA-kernel-module-source-610.43.03.tar.xz,
# extract_gsp.py off the .run installer, extract_boot_assets.py off the source
# tree; `install-firmware:` puts them at /usr/lib/firmware/gpu-unlock/610.43.03).
# kernel/gpu_unlock/recipes.h hardcodes the blob *names* it hands to the
# kernel's devm loader (kernel/gpu_unlock/firmware_610.c:20 calls
# request_firmware(fw, name, dev) with the GU_FW_* macros from recipes.h), so
# the lookup is relative to the kernel's built-in firmware search dirs
# (/lib/firmware, /lib/firmware/updates, /lib/firmware/extra):
# /lib/firmware/gpu-unlock/610.43.03/<name>.bin — inside the initrd.
{
  lib,
  stdenvNoCC,
  python3,
  zstd,
  xz,
  src, # gpu-unlock repo (carries firmware/extract_{gsp,boot_assets}.py)
  nvKernelSource, # NVIDIA-kernel-module-source-610.43.03.tar.xz
  nvInstaller, # NVIDIA-Linux-x86_64-610.43.03-no-compat32.run
}:

let
  nv = "610.43.03";
  nvSourceDir = "NVIDIA-kernel-module-source-${nv}";
  # The store layout hardware.firmware expects: config.hardware.firmware's
  # `apply` runs buildEnv { pathsToLink = [ "/lib/firmware" ] }, so blobs that
  # should end up at /lib/firmware/gpu-unlock/610.43.03/<name>.bin have to sit
  # under lib/firmware/ in this package. Anything outside that subtree is
  # dropped by buildEnv, and pkgs.compressFirmwareZstd (which nixpkgs applies
  # for kernels >= 5.19) walks `find lib/firmware -type f` and refuses a
  # package with no such subtree — so no symlinks here, plain files only.
  fwRel = "lib/firmware/gpu-unlock/${nv}";
  # Upstream Makefile FIRMWARE_FILES, verbatim.
  firmwareFiles = [
    "booter_load_ad102.bin"
    "booter_load_ga100.bin"
    "booter_load_ga102.bin"
    "booter_load_tu102.bin"
    "falcon_loader.bin"
    "gsp_boot_ad102.bin"
    "gsp_boot_desc_ad102.bin"
    "gsp_boot_ga100.bin"
    "gsp_boot_desc_ga100.bin"
    "gsp_boot_ga102.bin"
    "gsp_boot_desc_ga102.bin"
    "gsp_boot_tu102.bin"
    "gsp_boot_desc_tu102.bin"
    "gsp_ga10x.bin"
    "gsp_tu10x.bin"
    "sec2_bl_tu102.bin"
  ];
in
stdenvNoCC.mkDerivation {
  name = "gpu-unlock-firmware-${nv}";

  inherit src nvKernelSource nvInstaller;

  # zstd runs as a subprocess inside extract_gsp.py; xz lets tar read the .tar.xz.
  nativeBuildInputs = [
    python3
    zstd
    xz
  ];

  # nixpkgs' hardware.firmware runs every entry through
  # pkgs/compress-firmware.nix (hardware.firmwareCompression = "zstd" here),
  # which renames each blob to <name>.bin.zst. gpu-unlock's own packaging
  # installs plain .bin under /usr/lib/firmware/gpu-unlock/<ver>/, and the
  # NVIDIA blobs already on this box are plain .bin because nvidia-x11's
  # firmware package opts out (pkgs/os-specific/linux/nvidia-x11/generic.nix:308
  # `compressFirmware = false`) — same installer these blobs come from. Opt out
  # too: upstream names, and no 84 MB blob decompressed at initrd time.
  compressFirmware = false;

  # $src is read-only and the extractors write a tree of intermediates, so the
  # work happens in a scratch dir; only the listed blobs plus the license reach
  # $out (the untarred NVIDIA source tree never does), laid out under
  # $out/lib/firmware/gpu-unlock/610.43.03/ so the merged hardware.firmware
  # tree and the kernel's devm search dirs line up.
  buildPhase = ''
    runHook preBuild

    work=/tmp/gpu-unlock-fw-build
    rm -rf "$work"
    mkdir -p "$work/assets/src" "$work/assets"
    tar -xf "$nvKernelSource" -C "$work/assets/src"
    test -d "$work/assets/src/${nvSourceDir}/src/nvidia/generated"
    python3 "$src/firmware/extract_gsp.py" "$nvInstaller" "$work/assets"
    python3 "$src/firmware/extract_boot_assets.py" "$work/assets/src/${nvSourceDir}" "$work/assets"

    for f in ${lib.escapeShellArgs firmwareFiles}; do
      test -s "$work/assets/$f" || { echo "gpu-unlock: missing firmware blob $f"; exit 1; }
    done

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    work=/tmp/gpu-unlock-fw-build
    for f in ${lib.escapeShellArgs firmwareFiles}; do
      install -Dm644 "$work/assets/$f" "$out/${fwRel}/$f"
    done
    install -Dm644 "$work/assets/NVIDIA-LICENSE" "$out/${fwRel}/NVIDIA-LICENSE"
    # modules-closure.sh does `cd "$firmware"` and then `cp --parents
    # lib/firmware/$name`, so the subtree has to exist here already.
    test -d "$out/${fwRel}"

    runHook postInstall
  '';
}
