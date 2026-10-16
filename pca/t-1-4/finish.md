## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
#                        SOLUTION  (read only if stuck)                     #
#############################################################################

ROOT CAUSE
  The expression was:

      sum by (instance) (rate(node_cpu_seconds_total[5m]))

  node_cpu_seconds_total carries the labels: cpu, mode, instance, job.
  `by (instance)` tells sum() to keep ONLY `instance` and discard every
  other label — including `mode`. So all CPUs and all modes are added into
  one number per host. The dimension the rule name promised ("mode") is
  destroyed at aggregation time.

THE FIX — add `mode` back to the grouping list.
  Edit ${RULES_FILE} and change the expr to:

      expr: sum by (instance, mode) (rate(node_cpu_seconds_total[5m]))

  `by (instance, mode)` keeps exactly those two dimensions and collapses
  only the `cpu` (and `job`) dimension — which is what we actually want:
  one aggregated rate per host, per mode, summed across all cores.

EQUIVALENT FIX with the complementary modifier (know both for the exam):

      expr: sum without (cpu) (rate(node_cpu_seconds_total[5m]))

  `without (cpu)` keeps EVERYTHING except `cpu`. It therefore also retains
  `job`, giving the output series labels {instance, mode, job}. Choose:
    * `by`      when you want an explicit, minimal, whitelisted label set
                (stable output schema, immune to new labels appearing).
    * `without` when you want to strip a known nuisance label and keep the
                rest.
  Both restore the `mode` dimension and both make this lab pass.

APPLY AND RELOAD
      sed -i 's/sum by (instance)/sum by (instance, mode)/' ${RULES_FILE}
      curl -X POST ${PROM_URL}/-/reload

VERIFY
      $0 check
  Expected: "distinct mode dimensions" jumps from 1 to ~7-8, PASS.
  In the UI, `sum by (mode) (${RULE_NAME})` now shows one line per mode.

BONUS — the payoff of keeping the dimension: real CPU-busy ratio per host,
now computable because mode="idle" is separable again:

      1 - (
            sum by (instance) (${RULE_NAME}{mode="idle"})
          /
            sum by (instance) (${RULE_NAME})
          )

TAKEAWAYS
  * An aggregation's grouping modifier defines the output's dimensionality;
    it is not a filter, it is a projection.
  * `by` = whitelist of labels to KEEP; `without` = blacklist to DROP;
    bare aggregation keeps nothing and yields a single series.
  * A dimension lost to aggregation cannot be recovered downstream — the
    information is gone the moment the operator runs. Aggregate as late as
    possible and keep every dimension a consumer might still need.
#############################################################################
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/pca/1.4/lab)
