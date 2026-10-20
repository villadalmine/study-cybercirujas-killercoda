## Fix it

### Goals

1. The CPU is busy on an idle box. Find the process and stop it for good. Killing the PID is not enough: something restarts it, so look at its parent and the systemd unit.
2. The disk shows used space that du can't find. Find who still holds the deleted file and release it.

**Solved means:** Check passes when the systemd unit behind the CPU burner is stopped and disabled, no worker process of it is left, and no process holds a deleted file under the spool directory /var/tmp/lab-200.1.

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
