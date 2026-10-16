# Contributing a lab

Thanks for wanting to help! Labs are **written once** in the study repo and **published everywhere** from there,
Killercoda included. Please don't open pull requests here: this repository is generated and changes made here
are overwritten.

1. Open an issue in [study-cybercirujas](https://github.com/villadalmine/study-cybercirujas/issues/new/choose)
   using the **Lab** form, or pick an open lab issue.
2. Write the lab in `certs/<cert>/<topic>/lab/`, following the lab contract in the study repo's CONTRIBUTING:
   `lab.yaml` plus break, check, fix and cleanup.
3. Run `make pr-check` locally, then open the PR there. CI runs the full loop: break, check fails, fix,
   check passes, cleanup without leftovers. An independent review follows.
4. Sign off your commits (`git commit -s`, DCO) and declare whether you used AI and which tool. AI-assisted
   work is welcome when declared.
5. Once merged, the exporter generates the Killercoda scenario and publishes it here, under the course for
   that certification. You're credited in the study repo's CHANGELOG and contributors list.

Found a problem with a published scenario? Open the issue in the study repo and include the Killercoda URL.
