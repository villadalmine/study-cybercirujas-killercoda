## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION — do not read until you have fought with `lab-verify` for a while.

 Preparation
     source ~/az900-lab-3-1/lab.env
     cd ~/az900-lab-3-1
     lab-verify                      # 0/4 -- confirm the starting point

 FAULT 1 — wrong scope
 Concept: every Cost Management answer belongs to exactly one scope
 (management group, subscription, resource group, or an invoice/billing
 scope on an MCA/EA account). A cost query against the wrong scope is not an
 error, it is a different question. This is why the report showed ~USD 37:
 it was faithfully reporting the sandbox subscription.
     https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/understand-work-scopes

 Diagnosis
     az account show -o table
     az account list -o table

 Expected (broken):
     Name             Id                                    State    IsDefault
     ---------------  ------------------------------------  -------  ---------
     contoso-sandbox  22222222-2222-2222-2222-222222222222  Enabled  True

 Fix
     az account set --subscription contoso-platform-prod
     az account show --query name -o tsv          # -> contoso-platform-prod
     cost-report.sh                                # total jumps to ~4812.55

 FAULT 2 — unallocatable and drifted cost centre tags
 Concept: Cost Management can only group by what the usage record carries.
 Tags are the primary cost-allocation mechanism; they are not inherited by
 child resources, are not applied retroactively to past usage, tag NAMES are
 case-insensitive but tag VALUES are case-sensitive, and trailing whitespace
 is significant. Four resources have no CostCenter at all, and two have
 values that only look right: `cc-3003` and `CC-2002 ` (trailing space).
     https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/group-filter
     https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/tag-resources

 Diagnosis
     cost-report.sh --audit-tags
     az resource list --query "[?tags.CostCenter == null]" -o table

 Expected (broken): 4 rows listed as untagged; the drift block prints
     value <CC-2002 >  x1  rg-data-prod/stdataprod01  <-- does not match ^CC-[0-9]{4}$
     value <cc-3003>   x1  rg-edge-prod/vm-edge-jump-01  <-- does not match ...
     distinct CostCenter values: 5

 Fix — the mapping lives in policy/tagging-standard.md (RG -> cost centre):

     SUB=$(az account show --query id -o tsv)
     for rg_cc in "rg-platform-prod:CC-1001" "rg-data-prod:CC-2002" "rg-edge-prod:CC-3003"; do
       rg="${rg_cc%%:*}"; cc="${rg_cc##*:}"
       for id in $(az resource list -g "$rg" --query "[].id" -o tsv); do
         az tag update --resource-id "$id" --operation merge \
                       --tags "CostCenter=$cc" -o none 2>/dev/null \
           || az tag update --resource-id "$id" --operation merge --tags "CostCenter=$cc" >/dev/null
       done
     done

 (`--operation merge` keeps Environment and Owner; `replace` would delete
  them. `merge` also overwrites the drifted values with the canonical ones.)

     cost-report.sh --audit-tags        # distinct CostCenter values: 3, no drift
     az costmanagement query --type ActualCost --timeframe MonthToDate \
         --dataset-grouping name=CostCenter type=TagKey -o table

 Expected (fixed):
     PreTaxCost  TagKey      TagValue  Currency
     ----------  ----------  --------  --------
     2857.55     costcenter  CC-1001   USD
     1744.5      costcenter  CC-2002   USD
     210.5       costcenter  CC-3003   USD

 In production, close the loop with Azure Policy: a `deny` on resource
 creation without CostCenter, or `modify` + a remediation task to backfill.
 Note the timing rule — tagging today does not retag yesterday's usage.

 FAULT 3 — the budget
 Concept: a budget is a Microsoft.Consumption/budgets resource with a
 timeGrain, an amount, a time period and a set of notifications. It NOTIFIES;
 it never stops spending. A disabled notification with no recipients is a
 budget that exists only to look good in a compliance screenshot.
     https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-acm-create-budgets
     https://learn.microsoft.com/en-us/rest/api/consumption/budgets/create-or-update

 Diagnosis — deploy it and read the errors, one at a time:
     az deployment sub create --name budget-platform --location eastus \
         --template-file budgets/budget-platform-monthly.json

     ERROR: (InvalidTemplate) Deployment template file is not valid JSON: ...
         -> trailing comma after the "notifications" object
     ERROR: (InvalidTimeGrain) Budget 'platform-monthly': timeGrain 'Month' is
            invalid. Allowed: Monthly, Quarterly, Annually.
     ERROR: (InvalidStartDate) the start date must be the first day of a month

 Fix — edit budgets/budget-platform-monthly.json so the resource reads
 (replace YYYY-MM with the current month, and +1 year for endDate):

     {
       "type": "Microsoft.Consumption/budgets",
       "apiVersion": "2021-10-01",
       "name": "platform-monthly",
       "properties": {
         "category": "Cost",
         "timeGrain": "Monthly",
         "amount": 5300,
         "timePeriod": {
           "startDate": "YYYY-MM-01T00:00:00Z",
           "endDate":   "YYYY+1-MM-01T00:00:00Z"
         },
         "filter": {
           "dimensions": {
             "name": "ResourceGroupName",
             "operator": "In",
             "values": [ "rg-platform-prod", "rg-data-prod", "rg-edge-prod" ]
           }
         },
         "notifications": {
           "actual-80": {
             "enabled": true, "operator": "GreaterThan",
             "threshold": 80, "thresholdType": "Actual",
             "contactEmails": [ "finops@contoso.example" ],
             "contactRoles": [ "Owner" ]
           },
           "forecast-100": {
             "enabled": true, "operator": "GreaterThan",
             "threshold": 100, "thresholdType": "Forecasted",
             "contactEmails": [ "finops@contoso.example" ]
           }
         }
       }
     }

 Note the trailing comma after "notifications" must be gone, and the amount
 must be >= the current run-rate (4812.55) — 5300 gives ~10 % headroom, so
 the 80 % Actual alert fires at 4240, i.e. before the month runs away.

     az deployment sub create --name budget-platform --location eastus \
         --template-file budgets/budget-platform-monthly.json
     az consumption budget list -o table

 Expected (fixed):
     Name              Amount   TimeGrain  CurrentSpend  Consumed%  EnabledAlerts
     ----------------  -------  ---------  ------------  ---------  -------------
     platform-monthly  5300.00  Monthly    4812.55       90.8       2

 90.8 % > 80 % -> in a real subscription the Actual notification would have
 already fired to finops@contoso.example. That is the whole point of the
 exercise: the alert did not fail, it was never armed.

 FAULT 4 — the scheduled export
 Concept: scheduled exports push cost data (ActualCost / AmortizedCost /
 Usage) to a storage account on a recurrence, and they are how anything
 downstream — chargeback, BI, a FinOps warehouse — sees Azure cost. An export
 that is Inactive, or that writes to a directory nobody reads, produces no
 error at all; the consumer silently keeps serving the last good file.
     https://learn.microsoft.com/en-us/azure/cost-management-billing/costs/tutorial-improved-exports

 Diagnosis
     az costmanagement export list -o table
     ls -l exports/

 Expected (broken):
     Name              Type        Recurrence  Status    StorageDirectory     LastRun
     ----------------  ----------  ----------  --------  -------------------  -------
     daily-actualcost  ActualCost  Daily       Inactive  exports-archive-old

 Fix
     az costmanagement export update --name daily-actualcost \
         --storage-directory exports --status Active -o table

 The lab shim re-arms the schedule and runs it immediately; in Azure the next
 file appears at the next scheduled run, or right away via the Exports -
 Execute REST operation / "Run now" in the portal.

     cost-report.sh

 Expected (fixed): period equals the current YYYYMM, 10 resources, billed
 total USD 4812.55, no STALE warning.

 Final check
     lab-verify

     [PASS] 1. Cost queries run against the production scope
     [PASS] 2. Every production resource is allocatable to one cost centre
     [PASS] 3. A compliant monthly budget is deployed at subscription scope
     [PASS] 4. The scheduled ActualCost export is Active and lands where the
              report reads
     4/4 checks passing

 WHAT TO TAKE INTO THE EXAM (and into production)
 · Cost is always scoped. "How much are we spending?" is unanswerable until
   someone names the management group, subscription, resource group or
   billing scope.
 · Tags are the allocation mechanism, and they are fragile by design: not
   inherited, not retroactive, values case-sensitive. Enforce with Azure
   Policy, audit continuously — an untagged resource is not free, it is
   unattributable, which is worse.
 · A budget notifies, it does not cap. Alerting on Actual is a post-mortem;
   alerting on Forecasted is the only one that can still change the outcome.
   A budget below run-rate trains the team to ignore alerts.
 · Cost Analysis is for humans and ad-hoc questions; scheduled exports are
   for machines and for anything anyone downstream depends on. A broken
   export fails silently — monitor the freshness of the file, not just the
   existence of the job.
 · Other AZ-900 3.1 levers this lab deliberately does not simulate, and that
   you should be able to name: the Pricing Calculator and the Total Cost of
   Ownership (TCO) Calculator (pre-purchase estimation), Azure Reservations
   and Savings Plans, Azure Hybrid Benefit, spot VMs, right-sizing and
   Azure Advisor cost recommendations, and the factors that change price at
   all — region, resource type, bandwidth/egress, and the billing model
   behind the subscription.
     https://azure.microsoft.com/en-us/pricing/calculator/
     https://azure.microsoft.com/en-us/pricing/tco/calculator/
     https://learn.microsoft.com/en-us/azure/cost-management-billing/
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/az-900/3.1/lab)
