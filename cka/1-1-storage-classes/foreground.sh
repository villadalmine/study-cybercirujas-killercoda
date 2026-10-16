#!/bin/bash
echo "Preparing the lab (breaking the cluster on purpose)..."
until [ -f /tmp/lab-ready ]; do sleep 2; done
if [ -f /tmp/lab-broken ]; then echo "Lab ready. Start with: kubectl get pvc -A"; else echo "Lab setup FAILED, see /root/lab/break.log and report it: https://github.com/villadalmine/study-cybercirujas/issues/new/choose"; fi
