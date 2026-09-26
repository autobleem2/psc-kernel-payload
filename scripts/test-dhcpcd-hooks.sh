#!/usr/bin/env bash
#
# test-dhcpcd-hooks.sh — proves board/psc/overlay/lib/dhcpcd/dhcpcd-hooks/09-autobleem-wpa-driver
# actually gets wpa_supplicant_driver in front of 10-wpa_supplicant, the way dhcpcd-run-hooks
# really sources hooks (todo K9, 2026-09-26).
#
# Stages dhcpcd 9.4.1's own dhcpcd-run-hooks.in and hooks/10-wpa_supplicant (fetched from
# NetworkConfiguration/dhcpcd tag v9.4.1, BSD-2-Clause - the version Buildroot 2020.02.12
# installs) next to our 09-autobleem-wpa-driver hook, puts a fake wpa_supplicant/wpa_cli first
# in PATH that record their argv, and runs the real hook-sourcing loop with reason=PREINIT for a
# wireless interface - once with no wpa_supplicant_driver in the environment (what dhcpcd.conf's
# global "env" line fails to deliver on the console, K9's actual symptom) and once with dhcpcd
# having passed one through, to prove a real value still wins over our fallback.
#
# Runs on Windows Git Bash and Linux; needs curl and a POSIX /bin/sh. No sudo, nothing built.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS_DIR_SRC="${HERE}/board/psc/overlay/lib/dhcpcd/dhcpcd-hooks"
DHCPCD_TAG="v9.4.1"
RAW_BASE="https://raw.githubusercontent.com/NetworkConfiguration/dhcpcd/${DHCPCD_TAG}/hooks"

fail=0

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

echo "== fetching dhcpcd ${DHCPCD_TAG} (NetworkConfiguration/dhcpcd, BSD-2-Clause) =="
if ! curl -fsSL -o "${WORK}/dhcpcd-run-hooks.in" "${RAW_BASE}/dhcpcd-run-hooks.in"; then
	echo "  [BAD ] could not fetch dhcpcd-run-hooks.in - no network?"; exit 1
fi
if ! curl -fsSL -o "${WORK}/10-wpa_supplicant" "${RAW_BASE}/10-wpa_supplicant"; then
	echo "  [BAD ] could not fetch hooks/10-wpa_supplicant - no network?"; exit 1
fi
echo "  [ok ] fetched dhcpcd-run-hooks.in ($(wc -l < "${WORK}/dhcpcd-run-hooks.in") lines) and 10-wpa_supplicant"

# --- lay out a fake dhcpcd install: hookdir, sysconfdir (no enter/exit hook), rundir ---
HOOKDIR="${WORK}/hookdir"
SYSCONFDIR="${WORK}/etc"
RUNDIR="${WORK}/run"
mkdir -p "${HOOKDIR}" "${SYSCONFDIR}" "${RUNDIR}"

cp "${WORK}/10-wpa_supplicant" "${HOOKDIR}/10-wpa_supplicant"
cp "${HOOKS_DIR_SRC}/09-autobleem-wpa-driver" "${HOOKDIR}/09-autobleem-wpa-driver"
echo "== staged hooks (lexical order dhcpcd-run-hooks sources them in) =="
ls "${HOOKDIR}" | sort

# dhcpcd-run-hooks.in is a .in template - substitute only what the sourcing path we exercise
# actually uses outside a function body (@SERVICE*@/@STATUSARG@ sit inside detect_init(), which
# nothing here calls, so they are left as literal text - harmless, never executed).
sed \
	-e "s#@HOOKDIR@#${HOOKDIR}#g" \
	-e "s#@SYSCONFDIR@#${SYSCONFDIR}#g" \
	-e "s#@RUNDIR@#${RUNDIR}#g" \
	"${WORK}/dhcpcd-run-hooks.in" > "${WORK}/dhcpcd-run-hooks"

# --- fake wpa_supplicant / wpa_cli that just record their argv ---
FAKEBIN="${WORK}/fakebin"
mkdir -p "${FAKEBIN}"
ARGV_LOG="${WORK}/wpa_supplicant.argv"

cat > "${FAKEBIN}/wpa_cli" <<'EOF'
#!/bin/sh
# always "not running" - makes 10-wpa_supplicant's wpa_supplicant_start() proceed to actually
# start wpa_supplicant instead of treating it as already up.
exit 1
EOF
cat > "${FAKEBIN}/wpa_supplicant" <<EOF
#!/bin/sh
printf '%s\n' "\$*" > "${ARGV_LOG}"
exit 0
EOF
chmod +x "${FAKEBIN}/wpa_cli" "${FAKEBIN}/wpa_supplicant"

# a wpa_supplicant.conf with a ctrl_interface line - wpa_supplicant_start() refuses to run
# without one (10-wpa_supplicant: wpa_supplicant_ctrldir()).
WPA_CONF="${WORK}/wpa_supplicant.conf"
cat > "${WPA_CONF}" <<'EOF'
ctrl_interface=DIR=/tmp/wpa_ctrl
update_config=1
EOF

run_case()
{
	# $1 = label, $2 = "unset" or a wpa_supplicant_driver value to export, $3 = expected -D arg (or "" = none)
	label="$1"; driver_env="$2"; expect="$3"
	rm -f "${ARGV_LOG}"
	echo ""
	echo "== case: ${label} =="
	if [ "${driver_env}" = "unset" ]; then
		env -u wpa_supplicant_driver \
			PATH="${FAKEBIN}:${PATH}" \
			reason=PREINIT interface=wlan0 ifwireless=1 wpa_supplicant_conf="${WPA_CONF}" \
			/bin/sh "${WORK}/dhcpcd-run-hooks" >"${WORK}/run.log" 2>&1
	else
		env \
			PATH="${FAKEBIN}:${PATH}" \
			reason=PREINIT interface=wlan0 ifwireless=1 wpa_supplicant_conf="${WPA_CONF}" \
			wpa_supplicant_driver="${driver_env}" \
			/bin/sh "${WORK}/dhcpcd-run-hooks" >"${WORK}/run.log" 2>&1
	fi
	if [ ! -s "${ARGV_LOG}" ]; then
		echo "  [BAD ] wpa_supplicant was never started"; sed 's/^/    log: /' "${WORK}/run.log"; fail=1
		return
	fi
	argv="$(cat "${ARGV_LOG}")"
	echo "  wpa_supplicant argv: ${argv}"
	if [ -z "${expect}" ]; then
		case "${argv}" in
			*-D*) echo "  [BAD ] expected no -D at all, got one"; fail=1;;
			*) echo "  [ok ] no -D, as expected";;
		esac
		return
	fi
	case "${argv}" in
		*"${expect}"*) echo "  [ok ] argv carries ${expect}";;
		*) echo "  [BAD ] expected argv to carry ${expect}"; fail=1;;
	esac
}

# Case 1: what X6's global "env wpa_supplicant_driver=nl80211,wext" line fails to deliver on the
# console (K9's symptom) - dhcpcd-run-hooks runs with the variable unset. 09-autobleem-wpa-driver
# must default it before 10-wpa_supplicant reads it.
run_case "wpa_supplicant_driver unset (the console's actual environment)" unset "-Dnl80211,wext"

# Case 2: a value dhcpcd DID pass through must still win - proves ": ${var:=...}" is a default,
# not an override.
run_case "wpa_supplicant_driver=nl80211 already set" nl80211 "-Dnl80211"

echo ""
if [ "${fail}" = "0" ]; then
	echo "PASS: 09-autobleem-wpa-driver delivers the fallback driver list to 10-wpa_supplicant, and a real value still wins"
else
	echo "FAIL: see [BAD] lines above"
fi
exit "${fail}"
