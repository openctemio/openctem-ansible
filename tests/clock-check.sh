#!/usr/bin/env bash
# The clock check (preflight and end of roles/os_baseline) must fail on an
# unsynchronised or far-off clock and pass on a good one, with chronyc or, when
# chronyc is absent, with timedatectl. Stub binaries: no host touched.
#   tests/clock-check.sh [workdir]
set -euo pipefail
kit="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="${1:-$(mktemp -d)}"
mkdir -p "$work/bin"
export PATH="$work/bin:$PATH"

# stub NAME BODY: a script that prints BODY (or fails with 127 when BODY is -).
stub() {
	if [ "$2" = "-" ]; then
		printf '#!/usr/bin/env bash\nexit 127\n' > "$work/bin/$1"
	else
		printf '#!/usr/bin/env bash\ncat <<"OUT"\n%s\nOUT\n' "$2" > "$work/bin/$1"
	fi
	chmod +x "$work/bin/$1"
}
tracking() { # tracking OFFSET DIR LEAP
	printf 'Reference ID    : 0A000001 (ntp.example)\nSystem time     : %s seconds %s of NTP time\nLeap status     : %s\n' "$1" "$2" "$3"
}
run() { ansible-playbook -i localhost, "$kit/tests/clock-check.yml" "$@" > "$work/play.log" 2>&1; }
expect_pass() { run "${@:2}" || { cat "$work/play.log"; echo "FAIL: $1 should pass"; exit 1; }; echo "ok: $1"; }
expect_fail() {
	if run "${@:2}"; then cat "$work/play.log"; echo "FAIL: $1 should fail"; exit 1; fi
	grep -q 'chronyc makestep' "$work/play.log" || { cat "$work/play.log"; echo "FAIL: $1 message lacks the fix"; exit 1; }
	echo "ok: $1"
}

stub timedatectl "no"
stub chronyc "$(tracking 0.000012345 fast Normal)"
expect_pass "synchronised, tiny offset"
stub chronyc "$(tracking 14400.5 fast Normal)"
expect_fail "4 h fast"
stub chronyc "$(tracking 14400.5 slow Normal)"
expect_fail "4 h slow"
stub chronyc "$(tracking 0.1 fast 'Not synchronised')"
expect_fail "leap status not normal"
stub chronyc "$(tracking 7.5 fast Normal)"
expect_fail "offset above the default 5 s"
expect_pass "offset below a raised threshold" -e os_baseline_clock_max_offset=10
stub chronyc "garbage"
expect_fail "unparseable chronyc output"
stub chronyc -
expect_fail "no chronyc, not synchronised"
stub timedatectl "yes"
expect_pass "no chronyc, timedatectl synchronised"
echo "clock-check: all cases pass"
