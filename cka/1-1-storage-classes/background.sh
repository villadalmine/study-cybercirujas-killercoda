#!/bin/bash
# Waits for the node, makes sure a default StorageClass exists, then breaks the lab.
until kubectl get nodes 2>/dev/null | grep -q " Ready"; do sleep 2; done
if ! kubectl get storageclass 2>/dev/null | grep -q .; then
  kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.31/deploy/local-path-storage.yaml
  kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
fi
I_UNDERSTAND_THIS_IS_A_DISPOSABLE_VM=yes bash /root/lab/break_fix.sh break </dev/null > /root/lab/break.log 2>&1 && touch /tmp/lab-broken
touch /tmp/lab-ready
