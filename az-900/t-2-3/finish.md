## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION - do not read until you have scored at least 2/4 on your own

Load the lab identifiers first; every command below assumes them:

  source ~/az900-lab-2-3/lab.env      # exports SA, RG, LOCATION, CONTAINER
  KEY=$(az storage account keys list -g "$RG" -n "$SA" --query "[0].value" -o tsv)

LAYER 1 - NETWORK : the storage firewall is denying you
Diagnosis. The control plane answers, the data plane does not. That single
observation localises the fault, because the two live behind different
endpoints: management.azure.com (ARM, governed by Azure RBAC) versus
<account>.blob.core.windows.net (data, governed additionally by the account's
network rule set).

  az storage account show -g "$RG" -n "$SA" --query networkRuleSet
    {
      "bypass": "AzureServices",
      "defaultAction": "Deny",        <-- everything not explicitly allowed
      "ipRules": [],
      "virtualNetworkRules": []
    }

Fix A - production-shaped: keep Deny, allow only this host's egress address.

  MYIP=$(curl -fsS https://api.ipify.org)
  az storage account network-rule add -g "$RG" --account-name "$SA" --ip-address "$MYIP"
  # rule propagation is not instantaneous - allow up to ~60 seconds
  sleep 60
  az storage container list --account-name "$SA" --account-key "$KEY" -o table

Fix B - only if the lab VM is an Azure VM in the SAME region as the account.
Public-IP rules do not match that traffic: it never leaves the Azure
backbone, so the service sees a private source address. The correct answer
there is a virtual network rule backed by a service endpoint:

  az network vnet subnet update -g "$RG" --vnet-name <vnet> -n <subnet> \
      --service-endpoints Microsoft.Storage
  az storage account network-rule add -g "$RG" --account-name "$SA" \
      --vnet-name <vnet> --subnet <subnet>

Fix C - the blunt instrument. Acceptable in a throwaway lab, a finding in a
real audit, because it re-exposes the account to the whole public internet:

  az storage account update -g "$RG" -n "$SA" --default-action Allow

Exam framing: the firewall is a NETWORK control. It never grants access - it
only removes reachability. You still need a valid credential afterwards,
which is exactly what layer 2 is about to prove.

LAYER 2 - AUTHENTICATION : the application holds a rotated key
Diagnosis. Same HTTP 403, different error code: AuthenticationFailed with a
reference to the Authorization header signature. Shared Key authorization
works by having the client HMAC-sign a canonicalised request with the account
key; the service recomputes the signature with the key it currently holds. If
key1 was regenerated, every previously issued signature stops matching -
instantly, everywhere, for every client using that key.

  az storage account keys list -g "$RG" -n "$SA" --query "[].{name:keyName}" -o table

Fix - re-point the application at a currently valid credential:

  NEWCS=$(az storage account show-connection-string -g "$RG" -n "$SA" \
            --query connectionString -o tsv)
  printf 'AZURE_STORAGE_CONNECTION_STRING="%s"\n' "$NEWCS" > ~/az900-lab-2-3/app.env
  chmod 600 ~/az900-lab-2-3/app.env

The better fix, and the one the AZ-900 objectives actually want you to name.
Storage supports three authorization models, in increasing order of quality:

  1. Shared Key      - the account key. Full control over blob, file, queue
                       and table. Cannot be scoped, expired or attributed to
                       a person. One leak compromises the whole account.
  2. SAS token       - a signed URL: scoped to a resource, a permission set
                       and a time window. A user delegation SAS is signed
                       with an Entra ID credential rather than the account
                       key, so revoking the identity revokes the token.
  3. Microsoft Entra ID + Azure RBAC - no secret in the application at all.
                       A managed identity holds a role such as
                       'Storage Blob Data Reader', access is per-principal,
                       auditable, and key rotation becomes a non-event.

Demonstrate the third model, which would have made this fault impossible:

  ME=$(az ad signed-in-user show --query id -o tsv)
  SCOPE=$(az storage account show -g "$RG" -n "$SA" --query id -o tsv)
  az role assignment create --assignee-object-id "$ME" \
     --assignee-principal-type User \
     --role "Storage Blob Data Contributor" --scope "$SCOPE"
  # wait for RBAC propagation, then use no key at all:
  az storage blob list --account-name "$SA" -c "$CONTAINER" --auth-mode login -o table

LAYER 3 - EXISTENCE : the blob was deleted, and soft delete retained it
Diagnosis. BlobNotFound on read, but the account was created with a blob
delete-retention policy. A soft-deleted blob is retained for the configured
window and is simply hidden from ordinary listings.

  az storage account blob-service-properties show -g "$RG" --account-name "$SA" \
     --query deleteRetentionPolicy
    { "days": 7, "enabled": true }

  az storage blob list --account-name "$SA" --account-key "$KEY" \
     -c "$CONTAINER" --include d \
     --query "[].{name:name, deleted:deleted, ttl:properties.remainingRetentionDays}" -o table
    Name            Deleted    Ttl
    --------------  ---------  -----
    lesson-2-3.md   True       7

Fix - undelete restores the blob and all of its retained versions:

  az storage blob undelete --account-name "$SA" --account-key "$KEY" \
     -c "$CONTAINER" -n lesson-2-3.md
  az storage blob download --account-name "$SA" --account-key "$KEY" \
     -c "$CONTAINER" -n lesson-2-3.md -f /tmp/lesson-2-3.md && cat /tmp/lesson-2-3.md

Exam framing: soft delete is a RECOVERY control, not a backup, and its scope
is deliberately narrow. It protects against deletion and overwrite of an
object inside a retained window. It does not protect against the deletion of
the storage account itself, it does not survive the retention window, and it
is off by default on accounts created before it existed. Its companions in
the objective are blob versioning (keeps every prior version), point-in-time
restore (rolls a whole container back), and the resource lock
(`az lock create --lock-type CanNotDelete`) that stops the account from being
deleted at the control plane in the first place.

LAYER 4 - OBJECT STATE : the blob is in the Archive access tier
Diagnosis. The blob is listed with correct size and timestamps, yet every
read returns BlobArchived. Archive is OFFLINE storage: the data sits on the
cheapest media Azure offers, the metadata stays online so you can list, tag
and set properties, and no read is possible until the blob is copied back to
an online tier.

  az storage blob show --account-name "$SA" --account-key "$KEY" \
     -c "$CONTAINER" -n redundancy-diagram.txt \
     --query "{tier:properties.blobTier, status:properties.rehydrationStatus}"
    { "tier": "Archive", "status": null }

Fix A - rehydrate in place, asking for the expensive-but-fast priority:

  az storage blob set-tier --account-name "$SA" --account-key "$KEY" \
     -c "$CONTAINER" -n redundancy-diagram.txt --tier Hot --rehydrate-priority High

  az storage blob show --account-name "$SA" --account-key "$KEY" \
     -c "$CONTAINER" -n redundancy-diagram.txt \
     --query "{tier:properties.blobTier, status:properties.rehydrationStatus}"
    { "tier": "Archive", "status": "rehydrate-pending-to-hot" }

  The tier stays Archive and reads keep failing until the copy completes:
  typically under 1 hour at High priority for blobs below 10 GiB, up to 15
  hours at Standard. You cannot cancel a rehydration, and you cannot make it
  synchronous. That latency IS the product.

Fix B - when you need the data now and cannot wait: copy the archived blob to
a NEW blob in an online tier. The copy is served from the archive tier
asynchronously as well, but it leaves the original untouched and lets you
stage the destination however you like:

  az storage blob copy start --account-name "$SA" --account-key "$KEY" \
     --destination-container "$CONTAINER" --destination-blob redundancy-diagram-online.txt \
     --source-container "$CONTAINER" --source-blob redundancy-diagram.txt \
     --tier Hot --rehydrate-priority High

Exam framing - the four access tiers, and the single trade-off behind them.
You pay in two dimensions and they move in opposite directions: the colder
the tier, the lower the per-GiB storage price and the higher the per-GiB
access price, plus a minimum retention period whose early violation is
billed anyway.

  Hot     - highest storage cost, lowest access cost.  No minimum.
  Cool    - lower storage cost, higher access cost.     30-day minimum.
  Cold    - lower still, higher access cost again.      90-day minimum.
  Archive - lowest storage cost, highest access cost.  180-day minimum,
            OFFLINE: rehydration required before any read.

Hot/Cool/Cold can be switched instantly and are online throughout. Archive is
the only tier that changes the AVAILABILITY of the data, not just its price,
and it is per-blob only - it cannot be an account's default tier. In practice
you never set it by hand: an account lifecycle management policy moves blobs
down the tiers by age, for example
"tierToCool after 30 days without access, tierToArchive after 180, delete
after 2555", which is how a seven-year compliance retention costs almost
nothing to keep.

FINAL CHECK AND TEARDOWN
  ./az900-2.3-breakfix.sh verify     # expect SCORE 4/4
  ./az900-2.3-breakfix.sh cleanup    # delete the resource group

WHAT TO CARRY INTO THE EXAM - AND INTO PRODUCTION
  Four failures, four layers, one indistinguishable symptom ("I can't read
  the file") and, for the first three, one identical HTTP status code. The
  discriminator was never the status code; it was the Azure error code in the
  response body: AuthorizationFailure (network), AuthenticationFailed
  (credential), BlobNotFound (existence), BlobArchived (tier). Read the error
  code before you touch anything, work the layers from the bottom up, and
  re-verify after every single change so that a changing error message tells
  you that you are making progress.
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/az-900/2.3/lab)
