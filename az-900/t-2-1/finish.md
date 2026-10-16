## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
 SOLUTION - do not read until you have spent real time on 'hint 5'

 STEP 0 - enter the lab shell
   source ~/az900-lab-2.1/env.sh
   echo "$AZURE_CONFIG_DIR"
     /home/<user>/az900-lab-2.1/azure-config

   Everything below is scoped to that directory. Nothing you break here can
   reach your real ~/.azure.


 STEP 1 - find and repair the CLI defaults          (FAULT 1)
   az configure --list-defaults -o table
     Name      Source                                          Value
     --------  ----------------------------------------------  -----------------
     group     /home/<user>/az900-lab-2.1/azure-config/config  rg-az900-ghost
     location  /home/<user>/az900-lab-2.1/azure-config/config  westus5

   Prove that 'westus5' is fiction and pick a region that satisfies the
   design requirement (>= 3 availability zones):

   az account list-locations \
     --query "[?length(availabilityZoneMappings || \`[]\`) >= \`3\`].{region:name, zones:length(availabilityZoneMappings)}" \
     -o table
     Region        Zones
     ------------  -------
     eastus        3
     eastus2       3
     westus2       3
     westus3       3
     northeurope   3
     westeurope    3
     ...

   Pick one - eastus2 in this walkthrough - and set the defaults honestly:

   az configure --defaults group=rg-az900-lab21 location=eastus2
   az group show -o table
     Location    Name
     ----------  ---------------
     westus      rg-az900-lab21

   Note what just happened: the group resolves now, and its location is
   'westus' (0 zones) while your default deployment location is 'eastus2'.
   Those two facts are allowed to disagree. See STEP 5.


 STEP 2 - fix the deployment scope of the template  (FAULT 2)
   az deployment group validate -g rg-az900-lab21 -f ~/az900-lab-2.1/azuredeploy.json
     ERROR: (InvalidTemplate) Deployment template validation failed:
     'The template function 'resourceGroup' is not expected at this location.'

   The file declares a SUBSCRIPTION deployment but contains a resource-group
   resource. Swap the schema:

   sed -i 's#2018-05-01/subscriptionDeploymentTemplate.json#2019-04-01/deploymentTemplate.json#' \
     ~/az900-lab-2.1/azuredeploy.json

   grep '"\$schema"' ~/az900-lab-2.1/azuredeploy.json
     "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",

   The scope table, worth memorising for the exam:
     resource group    deploymentTemplate.json                 az deployment group create
     subscription      subscriptionDeploymentTemplate.json     az deployment sub create
     management group  managementGroupDeploymentTemplate.json  az deployment mg create
     tenant            tenantDeploymentTemplate.json           az deployment tenant create


 STEP 3 - deal with the inherited policy            (FAULT 4)
   az deployment group validate -g rg-az900-lab21 \
     -f ~/az900-lab-2.1/azuredeploy.json --parameters location=eastus2
     ERROR: (RequestDisallowedByPolicy) Resource 'nsg-az900-lab21' was
     disallowed by policy. Policy identifiers: '[{"policyAssignment":
     {"name":"az900-allowed-locations", ... "policyDefinition":
     {"name":"Allowed locations" ...

   Find where the rule is attached and what it allows:

   SUB=$(az account show --query id -o tsv)
   RGSCOPE="/subscriptions/$SUB/resourceGroups/rg-az900-lab21"

   az policy assignment list --scope "$RGSCOPE" -o table
     Name                     DisplayName                          Scope
     -----------------------  -----------------------------------  ----------------
     az900-allowed-locations  AZ-900 lab 2.1 - allowed locations   .../rg-az900-lab21

   az policy assignment show --name az900-allowed-locations --scope "$RGSCOPE" \
     --query parameters
     { "listOfAllowedLocations": { "value": [ "westus" ] } }

   THE PLATFORM-ENGINEER FIX - keep the guardrail, widen it deliberately:

   az policy assignment update --name az900-allowed-locations --scope "$RGSCOPE" \
     --params '{"listOfAllowedLocations":{"value":["westus","eastus2"]}}'

   (If your CLI version has no 'update' for assignments, delete and recreate
    with the corrected parameters - same result, same scope:
      az policy assignment delete --name az900-allowed-locations --scope "$RGSCOPE"
      az policy assignment create --name az900-allowed-locations --scope "$RGSCOPE" \
        --policy e56962a6-4747-49cd-b67b-bf8b01975c4c \
        --params '{"listOfAllowedLocations":{"value":["westus","eastus2"]}}' )

   The blunt fix - 'az policy assignment delete' - also unblocks you and is
   the wrong instinct in a landing zone: you removed a control instead of
   complying with it.


 STEP 4 - remove the management lock                (FAULT 5)
   az deployment group create -g rg-az900-lab21 --name az900-21 \
     -f ~/az900-lab-2.1/azuredeploy.json --parameters location=eastus2
     ERROR: (ScopeLocked) The scope '/subscriptions/<sub>/resourceGroups/
     rg-az900-lab21' cannot perform write operation because following
     scope(s) are locked: '.../rg-az900-lab21'. Please remove the lock and
     try again.

   az lock list -g rg-az900-lab21 -o table
     Name              Level     Notes
     ----------------  --------  ----------------------------
     lock-az900-lab21  ReadOnly  AZ-900 lab 2.1 - remove me

   az lock delete --name lock-az900-lab21 -g rg-az900-lab21

   Lock semantics for the exam: CanNotDelete allows reads and writes but
   blocks deletion; ReadOnly blocks every write, which is stricter than the
   Reader role and is why it broke a create. Locks are inherited by every
   child scope and are evaluated independently from RBAC - Owner does not
   bypass a lock, you must delete the lock first.


 STEP 5 - deploy, and answer the conceptual question   (FAULT 3)
   az deployment group create -g rg-az900-lab21 --name az900-21 \
     -f ~/az900-lab-2.1/azuredeploy.json --parameters location=eastus2 \
     --query "{state:properties.provisioningState, nsg:properties.outputs.nsgLocation.value}" -o table
     State      Nsg
     ---------  -------
     Succeeded  eastus2

   az network nsg show -g rg-az900-lab21 -n nsg-az900-lab21 \
     --query "{name:name, resourceLocation:location}" -o table
     Name             ResourceLocation
     ---------------  ------------------
     nsg-az900-lab21  eastus2

   az group show -n rg-az900-lab21 --query "{group:name, metadataLocation:location}" -o table
     Group            MetadataLocation
     ---------------  ------------------
     rg-az900-lab21   westus

   THE ANSWER: the resource group stays in 'westus' and that is correct.
   A resource group's location is where Azure stores the group's own metadata
   record (and it matters only for the availability of that metadata during a
   regional outage). It does not constrain, and is not inherited by, the
   resources inside the group. The workload's region is the location stamped
   on each resource - here, eastus2, which advertises three availability
   zones. Deleting and recreating the group to "move it" would have been
   wasted work built on a misunderstanding.

   Confirm the zone claim rather than trusting it:
     az account list-locations \
       --query "[?name=='eastus2'].availabilityZoneMappings[].logicalZone" -o tsv
       1
       2
       3
   Remember that logical zone 1 in YOUR subscription is not necessarily the
   same physical datacenter as logical zone 1 in someone else's - the mapping
   is per-subscription by design, so that Azure can balance load across the
   physical zones. The 'physicalZone' field in the same output is what
   actually identifies the datacenter set.


 STEP 6 - grade and clean up
   ./az900-2.1-breakfix.sh verify
   ./az900-2.1-breakfix.sh restore


 WHAT THE FIVE FAULTS MAP TO ON THE EXAM
   FAULT 1  client-side defaults          -> a "subscription/resource group
                                             context" question in disguise
   FAULT 2  template $schema              -> deployment scope: group, sub,
                                             management group, tenant
   FAULT 3  zoneless region + RG location -> regions, region pairs,
                                             availability zones, and the
                                             metadata-vs-resource location
                                             distinction
   FAULT 4  policy assignment at RG scope -> inheritance down the management
                                             group > subscription > RG >
                                             resource hierarchy
   FAULT 5  ReadOnly lock                 -> control-plane protection that is
                                             independent of RBAC

   All five failed at the SAME place: the Azure Resource Manager control
   plane, before any workload existed. That is the single sentence that ties
   topic 2.1 together - ARM is the one door, and every scope above the
   resource gets a vote on what comes through it.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/az-900/2.1/lab)
