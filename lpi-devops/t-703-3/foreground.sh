#!/bin/bash
echo "Preparing the lab..."
while [ ! -f /tmp/finished ]; do sleep 1; done
clear
if [ -f /tmp/study-lab-setup-failed ]; then echo "The lab setup failed: see /opt/study-lab/lpi-devops-703.3/break.out and /var/log/killercoda"; else cat /opt/study-lab/lpi-devops-703.3/break.out; fi
