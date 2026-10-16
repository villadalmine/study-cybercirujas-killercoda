#!/bin/bash
# Exit 0 only when the lab's own verify mode says solved.
export I_UNDERSTAND_THIS_IS_A_DISPOSABLE_VM=yes
export LAB_DISPOSABLE=yes
export STUDY_LAB=1
export TEACH_PLAT_LAB_CONFIRMED=yes
cd /opt/study-lab/cka-3.4 || exit 1
out=$(timeout 200 bash ./break_fix.sh check 2>&1)
code=$?
echo "$out"
[ "$code" -eq 0 ]
