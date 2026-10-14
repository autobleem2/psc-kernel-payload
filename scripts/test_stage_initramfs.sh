#!/usr/bin/env bash
#
# test_stage_initramfs.sh — host test of the build helpers for the new /init and the squashfs payload, run
# against a fake kernel tree (no kernel, no toolchain, no Buildroot):
#   * stage_initramfs (board/psc/stage-initramfs.sh) for AB_INIT=legacy and new, and a bad value: the staged
#     file list is exactly `init`, never src/, and legacy is byte-identical (and same mode) to the 2020 binary;
#   * make-squashfs.sh: the mksquashfs command line (a stub records it; the real tool is not needed);
#   * the sha256 sidecar format post-image.sh writes.
#
# Usage: scripts/test_stage_initramfs.sh
#
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT
fail=0
ok(){ printf 'ok   %s\n' "$*"; }
bad(){ printf 'FAIL %s\n' "$*"; fail=1; }
check(){ local what="$1"; shift; if "$@"; then ok "${what}"; else bad "${what}"; fi; }

# --- a fake psc-kernel tree: initramfs/init (the 2020 binary) + initramfs/src (Makefile that "builds" abinit) --
K="${T}/ksrc"
mkdir -p "${K}/initramfs/src"
printf 'legacy-binary\n' > "${K}/initramfs/init"; chmod 0755 "${K}/initramfs/init"
printf 'int main(void){return 0;}\n' > "${K}/initramfs/src/abinit.c"
printf 'x\n' > "${K}/initramfs/src/README.md"
cat > "${K}/initramfs/src/Makefile" <<'EOF'
CROSS_COMPILE ?= none-
abinit:
	echo "new-binary built with $(CROSS_COMPILE)" > $@
EOF

# shellcheck source=board/psc/stage-initramfs.sh
. "${HERE}/board/psc/stage-initramfs.sh"

files(){ ( cd "$1" && find . | LC_ALL=C sort | tr '\n' ' ' ); }

# legacy
stage_initramfs "${K}" "${T}/st-legacy" legacy "xx-" "${T}/scratch" >/dev/null
check "legacy: staged list is ./ ./init"       test "$(files "${T}/st-legacy")" = ". ./init "
check "legacy: no src/"                         test ! -e "${T}/st-legacy/src"
check "legacy: init byte-identical"             cmp -s "${K}/initramfs/init" "${T}/st-legacy/init"
check "legacy: mode kept"                       test "$(stat -c %a "${T}/st-legacy/init")" = 755
check "legacy: mtime kept"                      test "$(stat -c %Y "${T}/st-legacy/init")" = "$(stat -c %Y "${K}/initramfs/init")"

# new: built from src with the given prefix, staged as init
stage_initramfs "${K}" "${T}/st-new" new "xx-" "${T}/scratch" >/dev/null 2>&1
check "new: staged list is ./ ./init"           test "$(files "${T}/st-new")" = ". ./init "
check "new: no src/"                            test ! -e "${T}/st-new/src"
check "new: init is the built binary"           grep -q 'new-binary built with xx-' "${T}/st-new/init"
check "new: init executable"                    test -x "${T}/st-new/init"
check "new: kernel tree stays clean"            test "$(files "${K}/initramfs")" = ". ./init ./src ./src/Makefile ./src/README.md ./src/abinit.c "

# restaging replaces the old content (a dest that held something else)
mkdir -p "${T}/st-legacy/src"; touch "${T}/st-legacy/stale"
stage_initramfs "${K}" "${T}/st-legacy" legacy "xx-" "${T}/scratch" >/dev/null
check "restage: stale files and src/ are gone"  test "$(files "${T}/st-legacy")" = ". ./init "

# errors
check "bad AB_INIT is refused"                  bash -c '! ( . "$1"; stage_initramfs "$2" "$3" bogus x- "$4" ) >/dev/null 2>&1' _ \
	"${HERE}/board/psc/stage-initramfs.sh" "${K}" "${T}/st-bad" "${T}/scratch"
rm -rf "${T}/k2"; mkdir -p "${T}/k2/initramfs"; cp -a "${K}/initramfs/init" "${T}/k2/initramfs/init"
check "new without src/ is refused"             bash -c '! ( . "$1"; stage_initramfs "$2" "$3" new x- "$4" ) >/dev/null 2>&1' _ \
	"${HERE}/board/psc/stage-initramfs.sh" "${T}/k2" "${T}/st-nosrc" "${T}/scratch"

# --- make-squashfs.sh with a stub mksquashfs on PATH -----------------------------------------------------------
mkdir -p "${T}/bin" "${T}/tree/etc"
cat > "${T}/bin/mksquashfs" <<'EOF'
#!/bin/sh
echo "$*" > "$ARGS_FILE"
printf 'sqsh' > "$2"
EOF
chmod +x "${T}/bin/mksquashfs"
export ARGS_FILE="${T}/args"
HOST_DIR="" PATH="${T}/bin:${PATH}" bash "${HERE}/board/psc/make-squashfs.sh" "${T}/tree" "${T}/out.squashfs" >/dev/null
check "squashfs: image written"                 test -s "${T}/out.squashfs"
args="$(cat "${ARGS_FILE}" 2>/dev/null)"
for a in "-comp xz" "-Xbcj arm" "-b 256K" "-all-root" "-noappend"; do
	check "squashfs: option '${a}'"             test "${args#*"${a}"}" != "${args}"
done
check "squashfs: source tree is first arg"      test "${args%% *}" = "${T}/tree"

# --- sha256 sidecar: sha256sum format, bare file name, verifiable ----------------------------------------------
( cd "${T}" && cp out.squashfs abrootfs.squashfs && sha256sum abrootfs.squashfs > abrootfs.squashfs.sha256 )
check "sha256: one line '<64 hex>  abrootfs.squashfs'" \
	grep -Eq '^[0-9a-f]{64}  abrootfs\.squashfs$' "${T}/abrootfs.squashfs.sha256"
check "sha256: sha256sum -c passes"             bash -c 'cd "$1" && sha256sum -c abrootfs.squashfs.sha256 >/dev/null' _ "${T}"

# --- syntax of the real scripts -------------------------------------------------------------------------------
for s in board/psc/build-kernel.sh board/psc/stage-initramfs.sh board/psc/make-squashfs.sh board/psc/post-fakeroot.sh \
         board/psc/post-image.sh scripts/build.sh docker/run.sh; do
	check "bash -n ${s}"                        bash -n "${HERE}/${s}"
done

[ "${fail}" = 0 ] && echo "ALL OK" || { echo "FAILED"; exit 1; }
