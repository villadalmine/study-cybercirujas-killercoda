## Fix it

When you think it is solved, press **Check**.

<details><summary>Hint 1</summary>

uptime, then vmstat 1 5: is the run queue (r) above zero on a box with nothing to do?

</details>

<details><summary>Hint 2</summary>

top or ps: which process eats the CPU? pstree -p 1: who is its parent?

</details>

<details><summary>Hint 3</summary>

Kill it and look again a few seconds later. If it came back, who restarted it? systemctl status.

</details>

<details><summary>Hint 4</summary>

df -h /var/tmp against du -sh /var/tmp: where did the missing space go? lsof +L1.

</details>
