#!/bin/bash
echo "Preparing the lab (breaking the cluster on purpose)..."
until [ -f /tmp/lab-ready ]; do sleep 2; done
echo "Lab ready. Start with: kubectl get pvc -A"
