## Done

The lab's own check passed.

<details><summary>Reference solution</summary>

```
==== SOLUTION BEGIN ======================================================

WORKED SOLUTION -- 701.5 Software Composition, Licensing and Open Source
Do not read this until ./bin/build.sh has told you what it dislikes.

  cd ~/lab-701.5      # or $LAB_ROOT

STEP 0 -- read the commit before touching anything
  git log -p -1

Three version changes and one appended policy stanza. The policy stanza is
not part of "the bump" at all -- it is a previous engineer suppressing a
finding. Note that and come back to it.

FAULT 1 -- lock drift (gate 1/6)
Symptom: "lock drift: app/requirements.lock does not describe app/manifest.txt"

The manifest is human-owned intent; the lock is the resolved, reproducible
closure. They diverged because the manifest was edited by hand. Do NOT fix
this first: the lock must be regenerated from a manifest that is already
correct, so this is the LAST step. Look at what the new closure contains:

  ./bin/resolve.sh

Two names appear that nobody added by hand: idna-mini (pulled by httpx-lite)
and gpl-tabulate (pulled by fastcsv 2.0.0). Transitive dependencies are the
whole reason SCA exists -- your manifest is not your bill of materials.

FAULT 2 -- transitive copyleft contamination (gate 4/6)
Symptom: "gpl-tabulate==3.1.0 is GPL-3.0-only (deny) -- introduced by
          fastcsv==2.0.0"

  ./bin/why.sh gpl-tabulate
  # app/manifest.txt -> fastcsv==2.0.0 -> gpl-tabulate==3.1.0

fastcsv itself is still MIT. Its LICENSE did not change. What changed is what
it *pulls in*, and GPL-3.0-only obligations attach to the combined work you
convey: shipping widgetd as a closed-source binary that incorporates
gpl-tabulate would oblige you to offer the complete corresponding source of
the whole thing under GPLv3 (GPL-3.0, sections 5, 6 and 10).

The policy classifies it 'deny', and 'deny' is not waivable with an
exception -- an engineer under release pressure is exactly the wrong person
to relicense the product. The available answers are: change the distribution
model (a business decision, not yours), replace the dependency, or roll back.
The registry still carries the 1.x line, which has no dependencies at all:

  ls vendor/fastcsv/            # 1.4.2  2.0.0
  sed -i 's/^fastcsv==2\.0\.0$/fastcsv==1.4.2/' app/manifest.txt

(In a real repo you would also open a ticket: "fastcsv 2.x is blocked on
gpl-tabulate; either upstream makes it optional or we migrate off." Pinning
back is a hold, not a resolution.)

FAULT 3 -- known vulnerable component (gate 6/6)
Symptom: "LAB-2026-0001 [HIGH] httpx-lite==0.9.0 -- CRLF injection ...
          affected: >= 0.9.0, < 0.9.3   fixed in: 0.9.3"

The advisory database is CI-owned and hashed; editing it is the incident, not
the fix. Take the fixed version, which the registry has:

  ls vendor/httpx-lite/         # 0.9.0  0.9.3
  sed -i 's/^httpx-lite==0\.9\.0$/httpx-lite==0.9.3/' app/manifest.txt

Note that composition analysis answered a licensing question and a security
question from the same resolved graph. That is why SBOM generation sits at
the front of the pipeline rather than being a compliance afterthought.

FAULT 4 -- a policy that classifies non-identifiers (gate 3/6)
Symptom: "policy.conf: 'allow BSD' -- 'BSD' is not an SPDX identifier"
         "policy.conf: 'allow NOASSERTION' -- placeholders must never be
          classified"

  tail -5 policy.conf

Someone appended these to turn gate 4 green under release pressure. Read what
they actually do: "BSD" allows any of BSD-2-Clause, BSD-3-Clause and the
GPL-incompatible 4-clause advertising variant without distinguishing them,
and "NOASSERTION" -- SPDX's word for "nobody has looked yet" -- allows
literally every unexamined component that will ever enter the graph. The
suppression is worse than the finding it hid.

  sed -i '/^# TEMP -- WD-4471/,+2d' policy.conf
  tail -5 policy.conf              # confirm the stanza is gone

FAULT 5 -- declared vs concluded license (gate 4/6, appears after fault 4)
Re-run and the gate now says what the suppression was hiding:

  ./bin/build.sh
  # libyaml-ng  0.5.0  BSD  declared  UNCLASSIFIED

libyaml-ng 0.5.0 is a security release you were told to keep. Its metadata
declares "BSD". Because that is not a valid SPDX identifier, bin/sbom-gen.sh
stored it in CycloneDX's license.name, not license.id:

  jq '.components[] | select(.name=="libyaml-ng") | .licenses' build/sbom.cdx.json

That distinction is the point. An SBOM you hand a customer must not assert an
identifier nobody verified. So verify it -- read the license, do not guess:

  cat vendor/libyaml-ng/0.5.0/LICENSE

Three numbered conditions: retain the notice in source, reproduce it in
binary form and documentation, and -- the third one -- do not use the
holder's name to endorse derived products. Three clauses, with the
no-endorsement clause and without the 4-clause advertising requirement:
that is SPDX BSD-3-Clause. Record it as a *concluded* license with the
evidence you used (a TAB between fields; ^V TAB in vi, Ctrl-V TAB in bash):

  printf 'libyaml-ng==0.5.0\tBSD-3-Clause\tConcluded from vendor/libyaml-ng/0.5.0/LICENSE: three clauses including no-endorsement, no advertising clause.\n' \
    >> policy/overrides.conf

The SBOM will now emit license.id = BSD-3-Clause with
acknowledgement = "concluded", which is exactly the honest statement:
upstream did not tell us, we read the text and this is our conclusion.

Compare the two ways this could have been "fixed": 'allow BSD' asserts
nothing and permits everything; the override asserts one identifier for one
version, with a justification and an audit trail.

FAULT 6 -- Apache-2.0 section 4(d) NOTICE propagation (gate 5/6)
Symptom: "app/NOTICE has no '## httpx-lite==0.9.3' section, but the package
          ships a NOTICE"

build/THIRD-PARTY-NOTICES.txt is regenerated automatically and covers the
license-text-and-copyright obligation for every component. It cannot cover
this one: Apache-2.0 section 4(d) says that if the work you received includes
a NOTICE file, you must carry its attribution notices into your own
distribution. That is a human act of attribution, so it lives in a
human-owned file and it is the thing that silently rots on every bump.

  cat vendor/httpx-lite/0.9.3/NOTICE
  { echo; echo "## httpx-lite==0.9.3"; cat vendor/httpx-lite/0.9.3/NOTICE; } >> app/NOTICE

The checker requires the heading plus every non-empty upstream line verbatim
-- paraphrasing someone's attribution is not attribution. idna-mini needs no
section: it is BSD-3-Clause and ships no NOTICE, so the generated
THIRD-PARTY-NOTICES.txt discharges it. Do not add sections you do not owe.

STEP FINAL -- regenerate the lock, then verify
Only now is the manifest correct, so only now can the lock be right:

  cat app/manifest.txt
  # fastcsv==1.4.2 / libyaml-ng==0.5.0 / zlibish==1.0.7 /
  # mpl-metrics==2.3.0 / httpx-lite==0.9.3

  ./bin/resolve.sh --write-lock
  ./bin/build.sh
  # RELEASE OK  dist/widgetd-3.2.0.tar.gz

  bash lab-701.5-sca.sh verify

Final closure: six components. Five 'declared', one 'concluded'
(libyaml-ng). mpl-metrics stays green throughout on its recorded, ticketed,
dated exception -- that is what the 'review' category is for, and the
contrast with 'deny' is the whole lesson of the GPL fault.

  jq -r '.components[] | "\(.name)==\(.version)  \(.licenses[0].license.id // .licenses[0].license.name)  \(.licenses[0].license.acknowledgement)"' build/sbom.cdx.json

WHAT TO TAKE INTO THE EXAM, AND INTO PRODUCTION
* Your manifest is not your bill of materials. The transitive closure is, and
  only a resolver plus a lock file makes it reproducible.
* A package's own license tells you nothing about the license of what it
  pulls in. fastcsv stayed MIT the whole time.
* Copyleft strength is the axis that matters for a distribution decision:
  permissive (notice only) < file-level/weak (MPL, LGPL) < strong (GPL) <
  network (AGPL). Policy categories should encode that, not vendor opinion.
* Declared vs concluded is not bureaucracy. Upstream metadata is frequently
  absent, stale or ambiguous; the SBOM must record which of the two you are
  asserting, and CycloneDX 1.6 'acknowledgement' / SPDX
  LicenseDeclared vs LicenseConcluded exist precisely for that.
* "BSD", "GPL", "Apache" are not identifiers. SPDX ids are, and they are
  version- and variant-specific for good reasons.
* NOASSERTION in an allowlist is not a policy, it is the absence of one.
* Some obligations automate (shipping license texts); some do not
  (Apache-2.0 4(d) attribution). Know which is which before you promise a
  customer your pipeline handles compliance.
* A gate an engineer can waive alone is not a gate. Suppressed findings are
  the thing to grep for first when you inherit a red pipeline.

REFERENCES
  LPI exam 701 objectives     https://www.lpi.org/our-certifications/exam-701-objectives/
  SPDX License List           https://spdx.org/licenses/
  SPDX specification          https://spdx.github.io/spdx-spec/
  CycloneDX specification     https://cyclonedx.org/specification/overview/
  Apache License 2.0          https://www.apache.org/licenses/LICENSE-2.0
  GNU GPL v3                  https://www.gnu.org/licenses/gpl-3.0.html
  GNU license compatibility   https://www.gnu.org/licenses/license-list.html
  Mozilla Public License 2.0  https://www.mozilla.org/en-US/MPL/2.0/
  OSI approved licenses       https://opensource.org/licenses
  OSV vulnerability database  https://osv.dev/
  OpenSSF / SBOM guidance     https://openssf.org/

==== SOLUTION END ========================================================
```

</details>

---
Source and full course: [study.cybercirujas.club](https://study.cybercirujas.club) | [lab code](https://github.com/villadalmine/study-cybercirujas/tree/main/certs/lpi-devops/701.5/lab)
