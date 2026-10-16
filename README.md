# study-cybercirujas labs on Killercoda

Browser-ready labs from [study.cybercirujas.club](https://study.cybercirujas.club), published on Killercoda:
**https://killercoda.com/itrestauracion**

This repository is **generated**. The source of truth for every lab is
[villadalmine/study-cybercirujas](https://github.com/villadalmine/study-cybercirujas) (`certs/<cert>/<topic>/lab/`).
An exporter turns each lab into a Killercoda scenario, grouped by certification. The same lab also runs on your
laptop (Docker) or on your own cluster.

## Want to add or fix a lab?

Do it in the study repo, not here. A lab merged there is exported and published here automatically.
Read [CONTRIBUTING.md](CONTRIBUTING.md).

## Layout

- one folder per certification, each one a Killercoda course: `structure.json` plus an intro;
- one scenario per lab inside it: `index.json`, the steps, and `verify` scripts generated from the lab's check;
- `study-smoke/`: the sync smoke test.

Do not edit generated files by hand: the next export overwrites them.
