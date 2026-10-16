## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION (step by step) — do not read until you have tried

--- Step 1: Confirm the symptom and narrow down the layer --------------------

  kubectl -n audit-lab logs client --tail=4
    2026-09-30T10:12:03Z GET http://payments/
    curl: (6) Could not resolve host: payments
    result: HTTP 000

  kubectl -n audit-lab get svc payments
  kubectl -n audit-lab get endpointslices -l kubernetes.io/service-name=payments
    -> ClusterIP assigned, one endpoint with ready=true.

  curl exit code 6 is a name-resolution failure. No TCP connection was even
  attempted, so kube-proxy, the CNI and NetworkPolicy are not involved yet.
  The next place to look is DNS. Check which resolver the Pod uses:

  kubectl -n audit-lab exec client -- cat /etc/resolv.conf
    search audit-lab.svc.cluster.local svc.cluster.local cluster.local
    nameserver 10.96.0.10
    options ndots:5

--- Step 2: Turn on DNS query auditing in CoreDNS ------------------------------

  kubectl -n kube-system edit configmap coredns

  Add `log` to the server block, next to `errors`:

    .:53 {
        errors
        log
        health {
           lameduck 5s
        }
        ready
        ...

  In production, logging every query is noisy. The log plugin accepts class
  filters, for example `log . { class denial error }`, which logs only
  NXDOMAIN/NODATA and errors. Either form passes this lab.

  The `reload` plugin picks the change up by itself, but ConfigMap
  propagation plus the reload interval can take up to ~1-2 minutes.
  To apply it now:

  kubectl -n kube-system rollout restart deployment/coredns
  kubectl -n kube-system rollout status deployment/coredns

--- Step 3: Read the audit trail -------------------------------------------

  kubectl -n kube-system logs -l k8s-app=kube-dns -f --prefix | grep payments

  Expected output (IPs and IDs will differ):

  [INFO] 10.244.0.7:41822 - 5120 "A IN payments.audit-lab.svc.cluster.local. udp 52 false 512" NXDOMAIN qr,aa,rd 145 0.000112s
  [INFO] 10.244.0.7:41822 - 5377 "AAAA IN payments.audit-lab.svc.cluster.local. udp 52 false 512" NXDOMAIN qr,aa,rd 145 0.000098s
  [INFO] 10.244.0.7:36019 - 1901 "A IN payments.svc.cluster.local. udp 44 false 512" NXDOMAIN qr,aa,rd 137 0.000087s
  [INFO] 10.244.0.7:44710 - 7310 "A IN payments.cluster.local. udp 40 false 512" NXDOMAIN qr,aa,rd 133 0.000080s

  How to read one line:
    10.244.0.7:41822   -> client address:port (this is the client Pod's IP)
    5120               -> DNS message ID
    "A IN <name> udp 52 false 512" -> qtype, class, name, transport, request
                           size, DO bit, advertised UDP buffer size
    NXDOMAIN           -> response code
    qr,aa,rd           -> flags. 'aa' = authoritative: CoreDNS produced
                           this answer itself, not an upstream server
    0.000112s          -> time taken to answer

  The log also shows ndots:5 search-path expansion: the short name
  "payments" is tried against every search domain in turn. The FIRST query,
  payments.audit-lab.svc.cluster.local., is the correct FQDN of a Service
  that exists. The kubernetes plugin would answer it with NOERROR and the
  ClusterIP. Something that runs BEFORE the kubernetes plugin answers
  authoritatively with NXDOMAIN.

  Compare it with a name that does work:

  kubectl run dnsprobe -n audit-lab --rm -it --restart=Never \
    --image=busybox:1.36 -- nslookup kubernetes.default.svc.cluster.local
    -> resolves, and CoreDNS logs NOERROR qr,aa,rd for it.

  So only names under the audit-lab zone are affected.

--- Step 4: Find and remove the root cause -----------------------------------

  kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}'

  You will find:

      template IN ANY audit-lab.svc.cluster.local {
          match "(?i)^payments[.]audit-lab[.]svc[.]cluster[.]local[.]$"
          rcode NXDOMAIN
          fallthrough
      }

  CoreDNS runs plugins in the order compiled into plugin.cfg, not in the
  order written in the Corefile. `template` comes before `kubernetes`, so
  this block answers first, and `fallthrough` only passes on names that do
  not match the regex. This also explains why the `errors` plugin stayed
  silent: NXDOMAIN is a valid DNS response, not a plugin error.

  kubectl -n kube-system edit configmap coredns    # delete the whole template block, keep `log`
  kubectl -n kube-system rollout restart deployment/coredns
  kubectl -n kube-system rollout status deployment/coredns

  Restarting also clears the `cache` plugin, which would otherwise keep
  serving the cached NXDOMAIN (negative caching) for up to its TTL.

  Confirm with the logs:

  kubectl -n kube-system logs -l k8s-app=kube-dns --tail=50 | grep 'payments.audit-lab'
  [INFO] 10.244.0.7:52011 - 881 "A IN payments.audit-lab.svc.cluster.local. udp 52 false 512" NOERROR qr,aa,rd 116 0.000140s

  kubectl -n audit-lab logs client --tail=2
    result: HTTP 200

--- Step 5: Turn on structured L7 access auditing in the backend -------------

  kubectl -n audit-lab edit configmap payments-nginx

  Replace default.conf with (files under conf.d are included in nginx's
  `http {}` context, so `log_format` is valid here):

    log_format audit_json escape=json
      '{"time":"$time_iso8601",'
      '"remote_addr":"$remote_addr",'
      '"method":"$request_method",'
      '"uri":"$request_uri",'
      '"status":"$status",'
      '"bytes_sent":"$body_bytes_sent",'
      '"request_time":"$request_time",'
      '"user_agent":"$http_user_agent",'
      '"x_forwarded_for":"$http_x_forwarded_for"}';

    server {
        listen 8080;
        server_name _;

        # /var/log/nginx/access.log is a symlink to /dev/stdout in the
        # official image, so `kubectl logs` collects it.
        access_log /var/log/nginx/access.log audit_json;

        location = /healthz {
            access_log off;          # keep kubelet probes out of the audit trail
            default_type text/plain;
            return 200 "ok\n";
        }

        location / {
            default_type text/plain;
            return 200 "payments: ok\n";
        }
    }

  `escape=json` makes nginx escape quotes and control characters in
  variables such as the User-Agent. Without it, one crafted header breaks
  the JSON and can inject fake fields into your log pipeline.

  Apply it. The volume is not a subPath mount, so the kubelet refreshes the
  file within about a minute. Then validate and reload, or just restart:

  kubectl -n audit-lab exec deploy/payments -- nginx -t
  kubectl -n audit-lab exec deploy/payments -- nginx -s reload
  #   or: kubectl -n audit-lab rollout restart deployment/payments

--- Step 6: Correlate the two audit trails ------------------------------------

  kubectl -n audit-lab get pod client -o jsonpath='{.status.podIP}{"\n"}'
    10.244.0.7

  kubectl -n audit-lab logs deploy/payments --tail=3
  {"time":"2026-09-30T10:31:44+00:00","remote_addr":"10.244.0.7","method":"GET","uri":"/","status":"200","bytes_sent":"13","request_time":"0.000","user_agent":"curl/8.10.1","x_forwarded_for":""}

  The same source IP (10.244.0.7) appears in the CoreDNS log (the DNS
  question) and in the nginx log (the HTTP request). Pod-to-ClusterIP
  traffic is DNAT'd by kube-proxy but not SNAT'd, so the backend sees the
  real client Pod IP. If you see a node IP instead, something is
  masquerading the traffic (for example externalTrafficPolicy on a
  NodePort path, or a CNI masquerade rule), and that is worth auditing too.

  If you have jq, filter the stream:
  kubectl -n audit-lab logs deploy/payments | grep '^{' | jq -r 'select(.status != "200") | [.time, .remote_addr, .uri, .status] | @tsv'

--- Step 7 (optional): "Who changed the Corefile?" ------------------------------

  DNS and HTTP logs tell you WHAT happened to the traffic. The Kubernetes
  API audit log tells you WHO changed the configuration. If the
  kube-apiserver runs with --audit-policy-file and --audit-log-path
  (on kind: docker exec -it kind-control-plane bash), a policy rule like
  this records ConfigMap changes in kube-system:

    apiVersion: audit.k8s.io/v1
    kind: Policy
    rules:
      - level: RequestResponse
        verbs: ["create", "update", "patch", "delete"]
        resources:
          - group: ""
            resources: ["configmaps"]
        namespaces: ["kube-system"]
      - level: None

  and you would find this lab's change with:

    jq -c 'select(.objectRef.resource=="configmaps" and .objectRef.name=="coredns"
           and (.verb=="patch" or .verb=="update"))
           | {ts: .requestReceivedTimestamp, user: .user.username, verb, ua: .userAgent}' \
      /var/log/kubernetes/audit/audit.log

  Without an audit policy the API server records nothing, which is exactly
  the "nobody knows what changed" part of the ticket.

--- Step 8: Grade and clean up ---------------------------------------------

  ./break-fix-5.3.sh verify
  ./break-fix-5.3.sh reset
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/ckne/5.3/lab)
