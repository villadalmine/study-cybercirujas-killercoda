## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
============================  SOLUTION  ====================================
  Read only after you have genuinely tried. Every command below is real and
  was executed against this lab; the outputs are abridged for width.

STEP 0 — Triage: distinguish "not scheduled" from "not running"
  $ docker service ls
  ID       NAME            MODE         REPLICAS   IMAGE
  a1b2c3   lpi702_edge     replicated   0/2        nginx:1.27-alpine
  d4e5f6   lpi702_probe    replicated   1/1        alpine:3.20

  0/2 with a healthy probe service proves the cluster itself is fine: the
  engine is up, the overlay network exists, another service is running. The
  problem is specific to lpi702_edge.

  The single most useful command in swarm troubleshooting:

  $ docker service ps --no-trunc lpi702_edge
  ID      NAME           NODE  DESIRED STATE  CURRENT STATE  ERROR
  g7h8i9  lpi702_edge.1        Running        Pending 2m     "no suitable node (scheduling constraints not satisfied on 1 node)"
  j1k2l3  lpi702_edge.2        Running        Pending 2m     "no suitable node (scheduling constraints not satisfied on 1 node)"

  NODE is empty and CURRENT STATE is Pending: the task was never assigned,
  so no container was ever created. This is why 'docker logs' returns
  nothing — there is nothing to log. Scheduling failures are reported by the
  orchestrator in the task's ERROR field, not by the runtime.

STEP 1 — Fault 1: an unsatisfiable placement constraint
  $ docker service inspect --pretty lpi702_edge | sed -n '/Placement/,/Resources/p'
  Placement:
   Constraints:  [node.labels.tier == frontend]

  $ docker node inspect self --format '{{ json .Spec.Labels }}'
  {}

  The declaration asserts a cluster fact — "this workload belongs on nodes
  labelled tier=frontend" — that no node carries. Swarm never relaxes a
  constraint to make progress; the task waits forever. Two fixes exist, and
  choosing between them is an architecture decision, not a preference:

  FIX 1A (preferred here) — make the cluster fact true. The constraint
  expresses real intent (keep edge workloads on frontend nodes); the missing
  piece is node metadata. Label the node:

    $ docker node update --label-add tier=frontend "$(docker node ls -q)"
    kx9v2m1qb0p7...

    $ docker node inspect self --format '{{ json .Spec.Labels }}'
    {"tier":"frontend"}

  Node labels are manager-side metadata: adding one triggers immediate
  rescheduling of Pending tasks, no redeploy needed.

    $ docker service ps lpi702_edge
    NAME           NODE   DESIRED STATE  CURRENT STATE
    lpi702_edge.1  node1  Running        Starting 2s
    lpi702_edge.2  node1  Running        Starting 2s

  FIX 1B — delete the constraint, if the intent was wrong. Edit stack.yml,
  remove the placement block, and reconcile:

    $ cd /opt/lpi-lab/702.2 && docker stack deploy -c stack.yml lpi702
    Updating service lpi702_edge (id: a1b2c3)

  Do NOT reach for 'docker service update --constraint-rm ...' as the
  default: it makes the live state diverge from the file, and the next
  'docker stack deploy' silently reinstates the broken constraint. In a
  declarative system, fix the declaration.
  Reference: https://docs.docker.com/engine/swarm/services/#control-service-placement

STEP 2 — Fault 2: a healthcheck that probes a port nobody listens on
  With scheduling fixed, replicas oscillate:

  $ docker service ps lpi702_edge
  NAME               IMAGE               NODE   DESIRED STATE  CURRENT STATE       ERROR
  lpi702_edge.1      nginx:1.27-alpine   node1  Running        Starting 4s
  \_ lpi702_edge.1   nginx:1.27-alpine   node1  Shutdown       Failed 45s          "task: non-zero exit (137)"
  \_ lpi702_edge.1   nginx:1.27-alpine   node1  Shutdown       Failed 2 minutes ago "task: non-zero exit (137)"

  $ docker ps --filter "name=lpi702_edge" --format '{{.Names}}\t{{.Status}}'
  lpi702_edge.1.9k2m...   Up 34 seconds (unhealthy)

  Exit 137 = SIGKILL (128+9): the task did not crash on its own, it was
  killed. Ask the runtime why:

  $ CID=$(docker ps -q --filter "label=com.docker.swarm.service.name=lpi702_edge" | head -n1)
  $ docker inspect --format '{{ json .Config.Healthcheck.Test }}' "$CID"
  ["CMD-SHELL","wget -q -T 2 -O /dev/null http://127.0.0.1:8080/healthz || exit 1"]

  $ docker inspect --format '{{ json .State.Health.Log }}' "$CID" | tail -c 300
  ... {"ExitCode":1,"Output":"wget: can't connect to remote host (127.0.0.1): Connection refused"}

  Now confront that with what the process actually serves:

  $ docker exec "$CID" grep -n listen /etc/nginx/conf.d/default.conf
  2:    listen 80;

  $ docker exec "$CID" wget -q -O - http://127.0.0.1:80/healthz
  ok

  The endpoint exists and is correct — on port 80. The healthcheck probes
  8080. Three failures at 10s interval flip the container to unhealthy;
  swarm kills the unhealthy task and reschedules it, forever. The service
  is doing precisely what it was told.

  FIX 2 — correct the probe in the declaration:

    $ cd /opt/lpi-lab/702.2
    $ sed -i 's#http://127.0.0.1:8080/healthz#http://127.0.0.1:80/healthz#' stack.yml
    $ docker stack deploy --detach=true -c stack.yml lpi702
    Updating service lpi702_edge (id: a1b2c3)
    Updating service lpi702_probe (id: d4e5f6)

  The equivalent imperative form, for when you need the live fix first and
  the commit second (then still update the file):

    $ docker service update \
        --health-cmd 'wget -q -T 2 -O /dev/null http://127.0.0.1:80/healthz || exit 1' \
        --health-interval 10s --health-retries 3 --health-timeout 3s \
        lpi702_edge

  The other legitimate fix is to make reality match the declaration: add a
  'listen 8080;' to edge.conf and publish it. It is more work and changes
  the service contract, so it is the wrong call for an incident — but note
  the trap if you try it: swarm config objects are IMMUTABLE. Editing
  edge.conf and redeploying under the same config name fails with
  "config lpi702_edge_site already exists"; you must version the name
  (edge_site_v2) or 'docker config rm' it after removing every reference.
  Reference: https://docs.docker.com/engine/swarm/configs/

STEP 3 — Confirm convergence end to end
  $ docker service ls --filter name=lpi702_edge
  ID       NAME          MODE         REPLICAS   IMAGE
  a1b2c3   lpi702_edge   replicated   2/2        nginx:1.27-alpine

  $ docker ps --filter "name=lpi702_edge" --format '{{.Names}}\t{{.Status}}'
  lpi702_edge.1.7f3a...   Up 1 minute (healthy)
  lpi702_edge.2.b81c...   Up 1 minute (healthy)

  $ curl -s http://127.0.0.1:18080/healthz
  ok

  $ docker service logs --tail 2 lpi702_probe
  lpi702_probe.1@node1 | 2026-09-03T10:12:05+00:00 probe: edge OK
  lpi702_probe.1@node1 | 2026-09-03T10:12:10+00:00 probe: edge OK

  The probe line matters: it proves resolution of the service name 'edge' to
  the service VIP over the overlay network and load balancing across both
  replicas — the orchestration layer, not just the container.

  $ ./break-fix-702.2.sh verify
  [  ok ] 1/5 replicas converged (2/2)
  [  ok ] 2/5 all 2 task containers report healthy
  [  ok ] 3/5 published endpoint returns 'ok' through the ingress mesh
  [  ok ] 4/5 the healthcheck still probes /healthz (not disabled, not stubbed)
  [  ok ] 5/5 no task was rescheduled during the observation window
  PASS

  $ ./break-fix-702.2.sh cleanup

WHAT TO CARRY INTO PRODUCTION (and into the exam)
  1. Pending vs Failed is the first fork in every orchestration incident.
     Pending  -> the scheduler refused: constraints, resource reservations,
                 node availability (drain/pause), missing labels, placement
                 preferences. Diagnose with 'docker service ps --no-trunc'
                 and 'docker node ls/inspect'. There are no container logs.
     Failed   -> the runtime ran it and it died: image, command, config,
                 healthcheck, OOM. Diagnose with 'docker inspect' on the
                 task container and 'docker service logs'.
  2. Exit 137 in a task history is SIGKILL. Its two usual authors are the
     OOM killer (check .State.OOMKilled) and a failing healthcheck. They are
     trivially distinguished by 'docker inspect --format "{{json .State}}"'.
  3. A healthcheck is a contract, not decoration. It must probe the port and
     path the service really serves, or the orchestrator will faithfully
     destroy a perfectly working application. Deleting a failing healthcheck
     to make the dashboard green is how outages become silent.
  4. Constraints encode intent about the cluster. When one is unsatisfiable,
     first ask whether the missing node label is the real bug.
  5. Fix the declared state and re-apply. Imperative 'service update' is for
     the incident's first minute; the stack file is the source of truth, and
     'docker stack deploy' is idempotent by design.

  Objective coverage — LPI 701-100 v2.0, 702.2 Container Orchestration:
  container orchestration concepts, service/task/replica model, declarative
  stack deployment, service scaling and placement, service discovery over
  overlay networks, ingress publishing, container health and self-healing.
  https://www.lpi.org/our-certifications/exam-701-objectives/
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpi-devops/702.2/lab)
