#!/usr/bin/env bash
# Stands in for starch-backend under STARCH_FAKE=1: the same protocol, no disks.
# FAKE_FAIL=<step number> stops there with a failure, to see that screen.
set -u
declare -A ANS
source "$1"
echo "::plan 8"
n=0
for s in "Checking the medium" "Partitioning ${ANS[disk]:-/dev/x}" "Formatting and mounting" \
         "Installing Arch" "Configuring the system" "Installing the bootloader" \
         "Installing the Hyprland desktop" "Finishing"; do
    n=$((n + 1))
    echo "::step $s"
    for i in 1 2 3; do echo "working on $s ($i)"; sleep "${FAKE_DELAY:-0.05}"; done
    if [[ ${FAKE_FAIL:-0} == "$n" ]]; then echo "::fail $s failed (fake)"; exit 1; fi
    echo "::ok $s"
done
echo "::done"
