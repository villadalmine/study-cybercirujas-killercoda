## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
=== SOLUTION - step by step ================================================

Preparation, in every shell:

  source ~/helm-lab/env.sh
  echo "$HELM_REPOSITORY_CONFIG"     # ~/helm-lab/helm/repositories.yaml

FAULT 1 - the repository index does not describe the artifacts on disk

Step 1.1 - Confirm what the client believes:

  $ helm repo list
  NAME      URL
  labrepo   http://127.0.0.1:8879

  $ helm search repo labrepo/webapp --versions
  NAME            CHART VERSION   APP VERSION     DESCRIPTION
  labrepo/webapp  0.2.0           1.29            Lab chart for LPI 701 ...

Step 1.2 - Confirm what actually exists. An index is a claim; the tarballs
are the truth:

  $ ls -1 ~/helm-lab/repo/
  index.yaml
  webapp-0.1.0.tgz

  $ curl -s http://127.0.0.1:8879/index.yaml | head -20
  $ curl -sI http://127.0.0.1:8879/webapp-0.2.0.tgz | head -1
  HTTP/1.0 404 File not found

  The index advertises 0.2.0 (which nobody ever packaged) and omits 0.1.0
  (which is sitting right there). Its digest field is all zeros, so even if
  the tarball existed the checksum verification would fail.

Step 1.3 - Regenerate the index from the artifacts. This is the whole point
of `helm repo index`: it walks the directory, reads each .tgz, and writes
name/version/appVersion/digest/urls for what is really there.

  $ helm repo index ~/helm-lab/repo --url http://127.0.0.1:8879

  (Use --merge <old-index> when you are appending to a large public repo and
   do not want to lose entries whose tarballs live elsewhere.)

Step 1.4 - Refresh the client cache. Helm does not re-read the remote index
on every command; it uses ~/.cache/helm/repository/<repo>-index.yaml
(here redirected to $HELM_REPOSITORY_CACHE).

  $ helm repo update labrepo
  ...Successfully got an update from the "labrepo" chart repository
  Update Complete. Happy Helming!

  $ helm search repo labrepo/webapp --versions
  NAME            CHART VERSION   APP VERSION     DESCRIPTION
  labrepo/webapp  0.1.0           1.27            Lab chart for LPI 701 ...

  $ helm pull labrepo/webapp --version 0.1.0 --destination /tmp && ls /tmp/webapp-0.1.0.tgz
  /tmp/webapp-0.1.0.tgz

  Diagnostic worth remembering: if `helm search repo` disagrees with `curl`
  on the index, the problem is the cache; if `curl` itself shows the wrong
  content, the problem is the repository, and only `helm repo index` (or
  your CI publishing job) fixes it.

FAULT 2 - release stuck in pending-upgrade

Step 2.1 - Read the state. Helm 3's default storage backend is a Secret per
revision, in the release namespace, of type helm.sh/release.v1:

  $ helm status site -n helm-lab
  NAME: site
  STATUS: pending-upgrade
  REVISION: 2

  $ helm history site -n helm-lab
  REVISION  UPDATED  STATUS           CHART         APP VERSION  DESCRIPTION
  1         ...      deployed         webapp-0.1.0  1.27         Install complete
  2         ...      pending-upgrade  webapp-0.1.0  1.27         Preparing upgrade

  $ kubectl -n helm-lab get secrets -l owner=helm --show-labels
  NAME                        TYPE                 DATA  AGE  LABELS
  sh.helm.release.v1.site.v1  helm.sh/release.v1   1     5m   ...,status=deployed,version=1
  sh.helm.release.v1.site.v2  helm.sh/release.v1   1     5m   ...,status=pending-upgrade,version=2

Step 2.2 - Prove nothing is really running before you touch anything. A
genuine in-flight upgrade must not be interrupted:

  $ kubectl -n helm-lab get jobs,pods
  No resources found in helm-lab namespace.
  $ ps -ef | grep -c "[h]elm upgrade"
  0

  Only when both are empty is the pending revision stale.

Step 2.3 - Preferred fix, `helm rollback` to the last good revision. It is
transactional, it is auditable in `helm history`, and it is the documented
remedy:

  $ helm rollback site 1 -n helm-lab --wait --timeout 2m
  Rollback was a success! Happy Helming!

  $ helm status site -n helm-lab | head -4
  NAME: site
  STATUS: deployed
  REVISION: 3

Step 2.3-bis - Alternative fix when rollback is not viable (for example the
pending revision is 1, so there is nothing to roll back to): delete the
pending revision Secret. Surgery on release storage - do it deliberately,
and only after step 2.2:

  $ kubectl -n helm-lab delete secret sh.helm.release.v1.site.v2
  secret "sh.helm.release.v1.site.v2" deleted

  If the remaining latest revision is still labelled pending, promote it:

  $ kubectl -n helm-lab patch secret sh.helm.release.v1.site.v1 \
      --type=merge -p '{"metadata":{"labels":{"status":"deployed"}}}'

  (The label is what `helm list` filters on; the status inside the gzipped
   payload is what `helm status` prints. Deleting the bad revision entirely
   keeps the two consistent, which is why it beats patching labels.)

Step 2.4 - Prove the release is operable again with a real upgrade:

  $ helm upgrade site labrepo/webapp -n helm-lab --version 0.1.0 \
      --set message="production greeting v2" --wait --atomic --timeout 2m
  Release "site" has been upgraded. Happy Helming!

  $ kubectl -n helm-lab get configmap site-webapp -o jsonpath='{.data.index\.html}'
  <!doctype html>
  <html><body><h1>production greeting v2</h1></body></html>

  Note --atomic: it rolls back automatically on failure, which is precisely
  the flag that prevents this fault class in the first place. Pair it with
  --timeout, and in CI add `--wait`.

FAULT 3 - Chart.lock out of sync, charts/ empty

Step 3.1 - Read the two files that disagree:

  $ cat ~/helm-lab/src/platform/Chart.yaml | sed -n '/dependencies/,$p'
  dependencies:
    - name: webapp
      version: "0.1.0"
      repository: "@labrepo"
      condition: webapp.enabled

  $ cat ~/helm-lab/src/platform/Chart.lock
  dependencies:
  - name: webapp
    repository: "@labrepo"
    version: 0.0.9
  digest: sha256:0000...

  $ ls -A ~/helm-lab/src/platform/charts/
  (empty)

  Chart.yaml is the declaration, Chart.lock is the pinned resolution, and
  charts/ holds the vendored artifacts. `helm dependency build` installs
  exactly what the lock says and refuses to run when the lock's digest does
  not match Chart.yaml. `helm dependency update` re-resolves and rewrites
  the lock. Here Chart.lock is wrong, so `build` is not the command.

Step 3.2 - Re-resolve. This requires FAULT 1 to be fixed already, because
"@labrepo" is resolved through the repository index:

  $ helm dependency update ~/helm-lab/src/platform
  Hang tight while we grab the latest from your chart repositories...
  ...Successfully got an update from the "labrepo" chart repository
  Update Complete. Happy Helming!
  Saving 1 charts
  Downloading webapp from repo http://127.0.0.1:8879
  Deleting outdated charts

  $ ls -1 ~/helm-lab/src/platform/charts/
  webapp-0.1.0.tgz

  $ cat ~/helm-lab/src/platform/Chart.lock
  dependencies:
  - name: webapp
    repository: "@labrepo"
    version: 0.1.0
  digest: sha256:<real digest>
  generated: "<now>"

Step 3.3 - Render before you install. Always check that the subchart values
land where you think they do; parent values address a subchart under a key
named after the chart (or its alias):

  $ helm template platform ~/helm-lab/src/platform -n helm-lab | grep -A2 'name: platform-webapp'

Step 3.4 - Install:

  $ helm install platform ~/helm-lab/src/platform -n helm-lab --wait --timeout 2m
  NAME: platform
  STATUS: deployed
  REVISION: 1

  $ kubectl -n helm-lab get configmap platform-webapp platform-banner
  NAME              DATA   AGE
  platform-webapp   3      10s
  platform-banner   1      10s

  $ kubectl -n helm-lab get configmap platform-webapp -o jsonpath='{.data.index\.html}'
  <!doctype html>
  <html><body><h1>hello from the platform umbrella chart</h1></body></html>

  That last line proves the parent's values.yaml (webapp.message) overrode
  the subchart default - the mechanism the exam asks about.

GRADE AND CLEAN UP

  $ ./703.3-break-fix-helm.sh verify
  $ ./703.3-break-fix-helm.sh reset

WHAT TO TAKE TO THE EXAM
  * `helm repo index DIR --url URL` generates the index from the tarballs;
    `helm repo update` only refreshes the local cache. Different layers,
    different failures.
  * Helm 3 keeps release state in Secrets of type helm.sh/release.v1 named
    sh.helm.release.v1.<release>.v<rev>, in the release namespace. No Tiller,
    no cluster-wide state. `helm history` + `kubectl get secrets -l owner=helm`
    is the diagnostic pair.
  * "another operation is in progress" means a pending revision, not a
    running process. `helm rollback` first; delete the pending Secret only
    when there is nothing to roll back to.
  * `helm dependency build` = install what Chart.lock pins (reproducible, use
    in CI). `helm dependency update` = re-resolve and rewrite Chart.lock.
  * `--atomic --wait --timeout` on every upgrade is what stops fault 2 from
    ever happening in production.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpi-devops/703.3/lab)
