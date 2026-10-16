## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION (spoilers: try it yourself first)

Step 1: Confirm this is DNS, not the network or the Service.
  kubectl -n bf-data get svc orders-db                     # the Service exists and has a ClusterIP
  kubectl -n bf-app exec dnsutils -- getent hosts orders-db.bf-data.svc.cluster.local   # resolves
  kubectl -n bf-app exec dnsutils -- dig orders-db.legacy.internal.                     # NXDOMAIN
  The canonical name works but the legacy name does not, so the problem is
  the name mapping in CoreDNS.

Step 2: Read the configuration CoreDNS is using.
  kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}'

  You will find, inside the ".:53 {" block:
    rewrite stop {
        name regex ^([a-z0-9-]+)\.legacy\.internal\.$ {1}.bf-date.svc.cluster.local.
        answer name ^([a-z0-9-]+)\.bf-data\.svc\.cluster\.local\.$ {1}.legacy.internal.
    }
  and no "reload" line.

  The query name is rewritten to orders-db.bf-date.svc.cluster.local.
  Namespace "bf-date" does not exist, so the kubernetes plugin
  authoritatively answers NXDOMAIN for it. The "answer name" line expects
  bf-data, so it never matches either.

  Optional: watch it happen. Add "log" to the .:53 block temporarily, then:
    kubectl -n kube-system logs -l k8s-app=kube-dns -f
  The log shows the query with its original name and NXDOMAIN as the result.

Step 3: Fix the typo AND bring back the reload plugin.
  kubectl -n kube-system edit configmap coredns

  The .:53 block should look like this. Keep your cluster's other plugins
  exactly as they were:
    .:53 {
        # breakfix-ckne-2.3: map <name>.legacy.internal to Services in namespace bf-data
        rewrite stop {
            name regex ^([a-z0-9-]+)\.legacy\.internal\.$ {1}.bf-data.svc.cluster.local.
            answer name ^([a-z0-9-]+)\.bf-data\.svc\.cluster\.local\.$ {1}.legacy.internal.
        }
        errors
        health {
           lameduck 5s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
           pods insecure
           fallthrough in-addr.arpa ip6.arpa
           ttl 30
        }
        prometheus :9153
        forward . /etc/resolv.conf {
           max_concurrent 1000
        }
        cache 30
        loop
        reload
        loadbalance
    }

Step 4: The trap. You saved the ConfigMap, waited, and it is still NXDOMAIN.
  Without the "reload" plugin, CoreDNS never re-reads its Corefile. The
  kubelet does update the mounted file in each pod (after up to about a
  minute), but the running process ignores the change. Since the config
  running right now has no reload, restart CoreDNS this one time:
    kubectl -n kube-system rollout restart deployment coredns
    kubectl -n kube-system rollout status deployment coredns
  With "reload" back, future edits are picked up automatically: the kubelet
  syncs the ConfigMap to the volume, then reload notices the checksum change
  (it checks every 30s by default). A syntax error during a reload is logged,
  and the previous working config stays active.

Step 5: Verify.
  kubectl -n bf-app exec dnsutils -- getent hosts orders-db.legacy.internal
  kubectl -n bf-app exec dnsutils -- dig +noall +answer orders-db.legacy.internal.
    orders-db.legacy.internal. 30 IN A 10.96.x.y
  ./breakfix-ckne-2.3.sh verify

Why the details matter (exam-relevant mechanics):
  - The position of "rewrite" inside the block does not matter. CoreDNS runs
    plugins in the order fixed by plugin.cfg at compile time, and rewrite runs
    before kubernetes and forward. That is why the rewritten name reaches the
    kubernetes plugin.
  - "answer name" rewrites the response back to the name the client asked
    for. Without it, the answer's owner name (orders-db.bf-data.svc...) does
    not match the question, and stub resolvers such as glibc may discard it.
    dig shows an IP while getent/the application fail, which is a classic
    half-fix.
  - The regex is anchored with ^...\.$ on the fully qualified name, including
    the trailing dot. The pod has ndots:5 and search domains, so the resolver
    first tries names like orders-db.legacy.internal.bf-app.svc.cluster.local.
    An unanchored regex would also rewrite those search-path expansions.
  - "stop" ends rewrite processing after this rule matches; "continue" would
    let later rewrite rules apply as well.
  - For a whole external zone, rather than a name mapping, the usual tool is
    a separate server block with "forward" (a stub domain), for example:
      legacy.internal:53 {
          errors
          cache 30
          forward . 10.0.0.53
      }

Reset the lab at any time:  ./breakfix-ckne-2.3.sh restore
Remove everything:          ./breakfix-ckne-2.3.sh cleanup
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/ckne/2.3/lab)
