#!/bin/bash
# Not shown to the student: the parity test (study-lab test) runs it to prove the lab cleans up after itself.
export I_UNDERSTAND_THIS_IS_A_DISPOSABLE_VM=yes
export LAB_DISPOSABLE=yes
export STUDY_LAB=1
cd /opt/study-lab/lpic-2-200.1 || exit 1
timeout 300 bash ./break_fix.sh cleanup </dev/null
