#!/bin/sh
. "$(dirname -- "$0")/lib.sh"

command -v python3 >/dev/null 2>&1 || skip_all "python3 not found"

PPD=etc/tuned/ppd.conf
PERF=usr/lib/tuned/profiles/apex-performance/tuned.conf

# The stock profiles the mapping names are stand-ins: their shape, not their content.
mkroot() {
    r=$T/$1
    mkdir -p "$r/usr/bin" "$r/usr/lib/tuned/profiles" "$r/etc/tuned"
    cp -R "$IMAGE_DIR/system_files/etc/tuned/." "$r/etc/tuned/"
    cp -R "$IMAGE_DIR/system_files/usr/lib/tuned/profiles/." "$r/usr/lib/tuned/profiles/"
    stock_profile "$r" balanced '[main]\nsummary=stock\n\n[cpu]\npriority=10\ngovernor=schedutil|ondemand|powersave\nenergy_perf_bias=normal\nenergy_performance_preference=balance_performance\nboost=1\n\n[acpi]\nplatform_profile=balanced\n\n[audio]\ntimeout=10\n\n[disk]\n# devices=sda\n\n[scsi_host]\nalpm=med_power_with_dipm\n'
    stock_profile "$r" balanced-battery '[main]\nsummary=stock\ninclude=balanced\n\n[cpu]\nenergy_performance_preference=balance_power\n'
    # shellcheck disable=SC2016 # ${i:PROFILE_DIR} is TuneD's variable, written literally
    stock_profile "$r" powersave '[main]\nsummary=stock\n\n[cpu]\ngovernor=schedutil|conservative|powersave\nboost=0\n\n[acpi]\nplatform_profile=low-power|quiet\n\n[sysctl]\nvm.laptop_mode=5\n\n[script]\nscript=${i:PROFILE_DIR}/script.sh\n'
    stock_profile "$r" throughput-performance '[main]\nsummary=stock\n\n[cpu]\ngovernor=performance\nenergy_performance_preference=performance\nboost=1\n\n[acpi]\nplatform_profile=performance\n\n[vm]\ndirty_bytes = 40%%\n\n[disk]\nreadahead=>4096\n\n[sysctl]\nvm.swappiness=10\nnet.core.somaxconn=>2048\n'
    printf '#!/bin/sh\nexit 0\n' >"$r/usr/bin/tuned-ppd"
    chmod 0755 "$r/usr/bin/tuned-ppd"
    printf '%s\n' "$r"
}

stock_profile() {
    mkdir -p "$1/usr/lib/tuned/profiles/$2"
    # shellcheck disable=SC2059 # the format is the fixture
    printf "$3" >"$1/usr/lib/tuned/profiles/$2/tuned.conf"
}

power() {
    run env ROOT="$1" "$SH" "$CHECKS/power.sh"
}

# bad NAME ERE SNIPPET: the root edited by SNIPPET, run inside it, fails with a line matching ERE.
bad() {
    r=$(mkroot "$1")
    (cd "$r" && eval "$3")
    power "$r"
    expect_rc "$1: fails" 1
    expect_out "$1: says why" "$2"
}

r=$(mkroot good)
power "$r"
expect_rc "the committed ppd.conf and apex-performance pass" 0
expect_out "tuned-ppd would accept the file" "^PASS power: /etc/tuned/ppd\\.conf passes tuned-ppd's own validation$"
expect_out "the AC mapping is reported" '^PASS power: /etc/tuned/ppd\.conf \[profiles\] is balanced=balanced, performance=apex-performance, power-saver=powersave$'
expect_out "the battery mapping is reported" '^PASS power: /etc/tuned/ppd\.conf \[battery\] is balanced=balanced-battery$'
expect_out "apex-performance merges onto balanced" '^PASS power: TuneD profile apex-performance loads \(balanced \+ apex-performance\)$'
expect_out "the stock profiles load too" '^PASS power: TuneD profile balanced-battery loads \(balanced \+ balanced-battery\)$'
for kv in 'cpu governor=performance' 'cpu energy_performance_preference=performance' 'cpu boost=1' \
    'acpi platform_profile=performance'; do
    expect_out "apex-performance sets $kv" "^PASS power: apex-performance sets $kv\$"
done
expect_out "no server tunables" '^PASS power: apex-performance has no vm unit'
expect_no_out "nothing fails" '^FAIL'

expect_file "ppd.conf maps Performance to apex-performance" '^performance=apex-performance$' "$IMAGE_DIR/system_files/$PPD"
expect_file "apex-performance includes balanced" '^include=balanced$' "$IMAGE_DIR/system_files/$PERF"

bad no-file "^FAIL power: /etc/tuned/ppd\\.conf is missing" "rm $PPD"
bad no-profiles 'has no \[profiles\] section' "sed -i 's/^\\[profiles\\]\$/[modes]/' $PPD"
bad missing-mode 'no power-saver mode in \[profiles\]' "sed -i '/^power-saver=/d' $PPD"
bad duplicate-ac 'two modes share a TuneD profile on AC' "sed -i 's/^performance=.*/performance=balanced/' $PPD"
bad duplicate-battery 'two modes share a TuneD profile on battery' "sed -i 's/^balanced=balanced-battery\$/balanced=powersave/' $PPD"
bad no-battery-section 'battery_detection is on but there is no \[battery\] section' \
    "sed -i -e '/^\\[battery\\]\$/d' -e '/^balanced=balanced-battery\$/d' $PPD"
bad unknown-battery-mode '\[battery\] names modes that \[profiles\] lacks: turbo' "printf 'turbo=powersave\\n' >>$PPD"
bad unknown-profile 'unknown TuneD profiles: apex-performance' "rm -r usr/lib/tuned/profiles/apex-performance"
bad bad-default "the default mode 'turbo' is not in \\[profiles\\]" "sed -i 's/^default=.*/default=turbo/' $PPD"
bad not-boolean 'a \[main\] option is not a boolean' "sed -i 's/^sysfs_acpi_monitor=.*/sysfs_acpi_monitor=maybe/' $PPD"
bad unparsable 'does not parse \(While reading from' "printf '[profiles]\\nbalanced=balanced\\n' >>$PPD"

bad stock-performance 'expected exactly' "sed -i 's/^performance=.*/performance=throughput-performance/' $PPD"
bad no-battery-detection 'battery_detection off' "sed -i 's/^battery_detection=.*/battery_detection=false/' $PPD"
bad default-performance 'default mode is performance, expected balanced' "sed -i 's/^default=.*/default=performance/' $PPD"

bad governor 'cpu governor is powersave, expected performance' "sed -i 's/^governor=.*/governor=powersave/' $PERF"
bad no-boost 'cpu boost is 0, expected 1' "sed -i 's/^boost=.*/boost=0/' $PERF"
bad epp 'cpu energy_performance_preference is balance_performance, expected performance' \
    "sed -i '/^energy_performance_preference=/d' $PERF"
bad acpi 'acpi platform_profile is balanced, expected performance' "sed -i '/^\\[acpi\\]\$/,\$d' $PERF"
bad cpu-disabled 'cpu governor is not set' "sed -i '/^\\[acpi\\]\$/,\$d' $PERF && printf 'enabled=false\\n' >>$PERF"
bad server-include 'carries server tunables: a vm unit \(dirty_bytes\); disk readahead=>4096; sysctl vm\.swappiness; sysctl net\.core\.somaxconn$' \
    "sed -i 's/^include=.*/include=throughput-performance/' $PERF"
bad vm-section 'carries server tunables: a vm unit \(dirty_bytes\)' "printf '\\n[vm]\\ndirty_bytes=40%%\\n' >>$PERF"
bad sysctl 'carries server tunables: sysctl vm\.swappiness' "printf '\\n[sysctl]\\nvm.swappiness=10\\n' >>$PERF"
bad typed-unit 'carries server tunables: a vm unit' "printf '\\n[memory]\\ntype=vm\\ntransparent_hugepages=never\\n' >>$PERF"
bad missing-include "profile 'nope' \\(apex-performance -> nope\\) not found" "sed -i 's/^include=.*/include=nope/' $PERF"
# TuneD looks in /etc/tuned/profiles first: a local balanced there is what gets merged.
bad etc-override 'carries server tunables: sysctl vm\.dirty_ratio' \
    "mkdir -p etc/tuned/profiles/balanced && printf '[main]\\nsummary=local\\n\\n[sysctl]\\nvm.dirty_ratio=40\\n' >etc/tuned/profiles/balanced/tuned.conf"
bad no-tuned-ppd '^FAIL power: tuned-ppd is not installed' "rm usr/bin/tuned-ppd"

r=$(mkroot replace)
printf '[main]\ninclude=balanced\n\n[cpu]\nreplace=1\ngovernor=performance\nenergy_performance_preference=performance\nboost=1\n\n[acpi]\nplatform_profile=performance\n' \
    >"$r/$PERF"
power "$r"
expect_rc "a replaced [cpu] unit with the same values passes" 0

mkdir -p "$T/nopy"
# "$SH" too: the shell under test may be dash, which run.sh uses on Fedora.
for tool in "$SH" sh bash dirname mktemp rm cat; do
    if p=$(command -v "$tool"); then ln -sf "$p" "$T/nopy/$tool"; fi
done
r=$(mkroot nopython)
run env PATH="$T/nopy" ROOT="$r" "$SH" "$CHECKS/power.sh"
expect_rc "no python3 fails" 1
expect_out "and says why" '^FAIL power: python3 not available'

done_testing
