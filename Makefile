# Convenience wrapper around scripts/build.sh (which does the real work).
# Prefer running through the container:  docker/run.sh scripts/build.sh <cmd>
#
.PHONY: all setup kernel assemble payload verify menuconfig savedefconfig clean-out
all:            ; @scripts/build.sh all
setup:          ; @scripts/build.sh setup
kernel:         ; @scripts/build.sh kernel
assemble:       ; @scripts/build.sh assemble
payload:        ; @scripts/build.sh payload
verify:         ; @scripts/build.sh verify
menuconfig:     ; @scripts/build.sh menuconfig
savedefconfig:  ; @scripts/build.sh savedefconfig
# rebuild one package:  make pkg P=bluez5_utils
pkg:            ; @scripts/build.sh $(P)
clean-out:      ; rm -rf output
