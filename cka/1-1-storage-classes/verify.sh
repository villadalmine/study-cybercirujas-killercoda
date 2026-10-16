#!/bin/bash
I_UNDERSTAND_THIS_IS_A_DISPOSABLE_VM=yes bash /root/lab/break_fix.sh verify </dev/null 2>&1 | grep -q "Laboratorio resuelto"
