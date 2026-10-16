## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
SOLUTION — read only after '--verify' has failed you twice

The whole exercise is one idea: identity failures are layered, and you repair
them from the network upward. Bottom to top: name resolution -> authentication
-> authorization -> posture. Every step below is verified before moving on.

STEP 0 — make the tool honest again (FAULT 4, first half)
Before believing any output, prove the CLI is not silencing itself. A command
that prints nothing at all is a tooling symptom, not a cloud symptom.

  $ az config get core.output
  {
    "name": "output",
    "source": "/home/lab/.azure/config",
    "value": "none"
  }

  $ az config unset core.output
  $ az config unset core.only_show_errors
  $ az config get core.output
  ERROR: Configuration 'core.output' is not set.        # expected, means default (json)

Tip you should keep for the exam and for real life: an explicit '-o json' on
the command line always overrides the configured default, so
'az account show -o json' is the one-shot way to test this theory.

STEP 1 — restore the path to Microsoft Entra ID (FAULT 2)
  $ getent hosts login.microsoftonline.com
  127.0.0.1       login.microsoftonline.com

127.0.0.1 for a Microsoft endpoint is never legitimate. /etc/hosts is consulted
before DNS (see the 'hosts:' line in /etc/nsswitch.conf), so a single line here
outranks the whole resolver chain.

  $ sudo cp /etc/hosts /etc/hosts.bak
  $ sudo sed -i '/# >>> az900-2.4-breakfix >>>/,/# <<< az900-2.4-breakfix <<</d' /etc/hosts
  $ getent hosts login.microsoftonline.com
  20.190.xxx.xxx  login.microsoftonline.com          # a real Microsoft address

  $ curl -sS -o /dev/null -w '%{http_code}\n' https://login.microsoftonline.com/common/discovery/instance
  400        # a 400 here is SUCCESS: TLS completed and Entra ID answered.
             # Connection refused / timeout would mean the path is still broken.

Why this is step 1: interactive sign-in, MFA, passwordless and Conditional
Access are all evaluated by Entra ID at this endpoint. With it unreachable, the
device can present no identity at all, and every later diagnostic lies to you.

STEP 2 — re-authenticate (FAULT 1)
  $ az account show
  ERROR: Please run 'az login' to setup account.

The correct fix is to authenticate again, not to copy the cache back. On a
headless build agent use the device code flow:

  $ az login --use-device-code
  To sign in, use a web browser to open the page https://microsoft.com/devicelogin
  and enter the code XXXXXXXXX to authenticate.

What you are watching happen, in exam vocabulary:
  * The device code flow separates the device from the browser doing the sign-in.
  * The browser session is where SSO applies: if you already authenticated to
    another Microsoft app in that browser, no credential is requested again.
  * If MFA is required you are challenged now (Authenticator push, FIDO2 key,
    Windows Hello, passkey — the passwordless methods of objective 2.4).
  * If a Conditional Access policy denies the sign-in you will see the reason
    encoded in the AADSTS error, not a generic failure:
        AADSTS50076  MFA required, interaction needed
        AADSTS53003  access blocked by a Conditional Access policy
        AADSTS50158  external security challenge not satisfied
        AADSTS700082 refresh token expired due to inactivity
        AADSTS7000215 invalid client secret
    Always read the AADSTS code. It names the control that stopped you.

  $ az account show -o table
  Name            CloudName    SubscriptionId                        State    IsDefault
  --------------  -----------  ------------------------------------  -------  ---------
  Sandbox-AZ900   AzureCloud   xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx  Enabled  True

The fallback, valid only in this lab, is restoring the cached tokens:
  $ cp ~/.az900-breakfix/backup-*/_home_lab_.azure_msal_token_cache.json ~/.azure/msal_token_cache.json
  $ cp ~/.az900-breakfix/backup-*/_home_lab_.azure_azureProfile.json     ~/.azure/azureProfile.json
It works because those files ARE the credential. That is the lesson: never back
up a token cache, and shred this one when the lab is over:
  $ shred -u ~/.az900-breakfix/backup-*/*msal_token_cache.json

STEP 3 — restore the managed identity path (FAULT 3, Azure VM only)
  $ ip route get 169.254.169.254
  RTNETLINK answers: Network is unreachable

  $ ip route show 169.254.169.254
  blackhole 169.254.169.254

'blackhole' is a local kernel decision, not a cloud one and not a firewall one.
Diagnostic rule worth memorising:
    Network is unreachable  -> routing (ip route)
    Connection refused      -> something answered and said no (local listener, proxy)
    Timed out               -> silently dropped (firewall DROP, NSG deny, black hole in path)

  $ sudo ip route del blackhole 169.254.169.254/32
  $ ip route get 169.254.169.254
  169.254.169.254 dev eth0 src 10.0.0.4 uid 1000

  $ curl -s -H "Metadata: true" \
      "http://169.254.169.254/metadata/instance?api-version=2021-02-01" | jq .compute.name
  "vm-az900-lab"

  $ curl -s -H "Metadata: true" \
      "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://management.azure.com/" \
      | jq '{token_type, expires_in, client_id}'
  {
    "token_type": "Bearer",
    "expires_in": "86399",
    "client_id": "cccccccc-cccc-cccc-cccc-cccccccccccc"
  }

  $ az login --identity                       # system-assigned
  $ az login --identity --client-id <client-id-of-the-uami>   # user-assigned, az >= 2.68
  # older CLI builds use:  az login --identity --username <client-id>

Concepts proved here, all examinable:
  * A managed identity is a service principal in Entra ID with no credential you
    ever handle; Azure rotates it. System-assigned dies with the resource,
    user-assigned is an independent object you can attach to many resources.
  * The token is fetched from a link-local address that must never be reachable
    from outside the VM. If it were, the identity would be stealable.
  * The token is only authentication. What the identity may DO comes from role
    assignments — the next step.

STEP 4 — clear the scope trap and read RBAC correctly (FAULT 4, second half)
  $ az configure --list-defaults -o table
  Name    Source                        Value
  ------  ----------------------------  ---------------------
  group   /home/lab/.azure/config       rg-az900-scope-trap

  $ az configure --defaults group=''
  $ az configure --list-defaults -o table        # empty

Now practise reading an authorization failure. The real message names the three
components of every Azure role assignment:

  (AuthorizationFailed) The client 'dev@contoso.com' with object id 'a1b2c3d4-...'
    does not have authorization to perform action 'Microsoft.KeyVault/vaults/read'
    over scope '/subscriptions/<sub>/resourceGroups/rg-app-prod' or the scope is invalid.
     ^ security principal                ^ action from a role definition        ^ scope

  $ MYID=$(az ad signed-in-user show --query id -o tsv)
  $ az role assignment list --assignee "$MYID" --all -o table
  Principal        Role         Scope
  ---------------  -----------  ------------------------------------------------
  dev@contoso.com  Reader       /subscriptions/xxxx
  dev@contoso.com  Contributor  /subscriptions/xxxx/resourceGroups/rg-app-dev

What to take to the exam:
  * Scope hierarchy: management group > subscription > resource group > resource.
    Assignments are inherited downward and are additive.
  * Allow is additive; an explicit deny assignment always wins over any allow.
  * Least privilege means picking the narrowest built-in role at the narrowest
    scope: 'Key Vault Secrets User' on one vault, not 'Contributor' on the
    subscription. Owner/Contributor/Reader/User Access Administrator are the four
    you must be able to distinguish; only Owner and User Access Administrator can
    grant access to others.
  * RBAC governs the Azure control plane (management.azure.com). What a user may
    do INSIDE Microsoft Entra ID is governed by directory roles (Global
    Administrator, User Administrator...), which is a different system. Do not
    mix them up — the exam does.

STEP 5 — remove the credential, not just the file (FAULT 5)
  $ ls -l ~/az900-lab/app/appsettings.json
  -rw-r--r--. 1 lab lab 412 Sep  6 10:02 appsettings.json      # world readable

  $ env | grep AZURE_
  AZURE_TENANT_ID=00000000-0000-0000-0000-0000000000aa
  AZURE_CLIENT_ID=00000000-0000-0000-0000-0000000000bb
  AZURE_CLIENT_SECRET=FAKE~DO.NOT.USE-0000000000000000000000000

Remediate all three surfaces — disk, shell startup, current process:

  $ shred -u ~/az900-lab/app/appsettings.json      # or strip the secret and: chmod 600
  $ sed -i '/# >>> az900-2.4-breakfix env credentials >>>/,/# <<< az900-2.4-breakfix env credentials <<</d' ~/.bashrc
  $ unset AZURE_CLIENT_SECRET AZURE_CLIENT_ID AZURE_TENANT_ID
  $ exec bash -l                                    # prove it in a fresh login shell
  $ env | grep -c AZURE_
  0

Then replace the pattern, do not just delete it. The application should read its
configuration from Azure Key Vault, authenticating with the VM's managed identity:

  # conceptual, control-plane commands an admin would run in a real subscription:
  az keyvault set-policy ... (vault access policy model)         # legacy model
  az role assignment create \
      --assignee <managed-identity-client-id> \
      --role "Key Vault Secrets User" \
      --scope /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/<vault>
  # least privilege: 'Secrets User' can read secret values, and nothing else,
  # in exactly one vault. Not 'Contributor', which can read the vault's config
  # but is also far broader than the task requires.

And in code, DefaultAzureCredential now resolves to the managed identity because
the environment no longer hijacks the chain:
  EnvironmentCredential -> WorkloadIdentityCredential -> ManagedIdentityCredential
    -> SharedTokenCacheCredential -> AzureCliCredential -> ...
The first credential that is *available* wins; if it is available but fails
(a wrong secret), the chain stops with an error instead of falling through.
That is precisely why a stale AZURE_CLIENT_SECRET breaks a perfectly good VM.

STEP 6 — verify, then close the loop with posture
  $ ./az900-2.4-identity-breakfix.sh --verify
  [ ok ] 1. Azure CLI session — signed in, subscription 'Sandbox-AZ900'
  [ ok ] 2. Entra ID endpoint — login.microsoftonline.com -> 20.190.xxx.xxx
  [ ok ] 3. Managed identity path — IMDS answers at 169.254.169.254
  [ ok ] 4. CLI scope defaults — no bogus default group, output format 'json'
  [ ok ] 5. Secret hygiene — no plaintext secret on disk, no AZURE_CLIENT_SECRET in env
  ALL CHECKS PASSED (5).

Finally, the part of objective 2.4 that no local command can prove: the reason
you found any of this is that someone was watching. Microsoft Defender for Cloud
is the CNAPP that continuously assesses these resources, expresses the result as
Secure Score, and issues the remediation recommendations — including "Machines
should have secrets findings resolved" and "Management ports should be closed".

  $ az extension add --name security
  $ az security secure-scores list -o table
  Name    DisplayName     Weight  Current  Max  Percentage
  ------  --------------  ------  -------  ---  ----------
  ascScore  ASC score        18       32   45        0.71

THE FIVE SENTENCES TO REMEMBER
 1. Microsoft Entra ID is the identity provider; the local machine only caches
    the tokens it issued. Deleting the cache does not delete the identity.
 2. Authentication (who you are: SSO, MFA, passwordless, Conditional Access)
    always precedes authorization (what you may do: Azure RBAC). Every incident
    is one or the other, and treating them as one costs you the diagnosis.
 3. An RBAC assignment is principal x role definition x scope, inherited
    downward from management group to resource; deny assignments beat allows.
 4. A managed identity removes the credential from your code, your disk and your
    backups: the VM asks IMDS at 169.254.169.254 and Azure hands it a token.
 5. Defense in depth means these controls stack — network, identity,
    authorization, host hygiene, monitoring — and Zero Trust means none of them
    is trusted because of where the request came from. Verify explicitly, grant
    least privilege, assume breach.

Reference: https://learn.microsoft.com/en-us/credentials/certifications/resources/study-guides/az-900
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/az-900/2.4/lab)
