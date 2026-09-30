# pve-backup-drill

Proxmox VE 虛擬機的備份與還原演練工具。搭配 QNAP HDP for Business 使用，但不依賴它。備份工具負責備份，這裡負責證明備份還得回來，並把還原時間（RTO）與資料損失（RPO）量成數字。

| 檔案 | 跑在哪 | 做什麼 |
|---|---|---|
| `canary.sh` | 客體 VM 內 | 每分鐘寫一筆心跳並 fsync，保存一份固定 payload 與其 sha256。還原後 `verify` 找出最後一個心跳斷層，斷層前一筆就是還原點，payload 校驗證明資料完整 |
| `restore-drill.sh` | PVE 節點，或任何有 ping、nc、ssh 的機器 | 按下還原時啟動，依序等 VM 存在、running、ping、SSH、canary 驗證，印出 drill-log 的一列與 JSONL |
| `policy.md` | 文件 | 備份對象、排程、保留、不可變、驗證、異地與 Airgap+ 的設定與依據，附實測到的邊界 |
| `drill-log.md` | 文件 | 四個還原演練與紀錄表 |
| `tests/fake-flow.sh` | 任何 Linux | 以假的 `qm`、`ping`、`nc`、`ssh` 跑完整流程 |

## 用法

在每台要備份的 VM 裡裝一次（需要 cron）。

```sh
sudo ./canary.sh install
```

演練步驟：

1. 停掉原 VM，記下時間，這就是模擬的故障時間。還原出來的 VM 沿用同一個 MAC 與 IP，原 VM 還在跑的話，ping 與 SSH 會打到原機。
2. 按下還原的同時執行 `restore-drill.sh`。

還原到 PVE（新 VMID）：

```sh
./restore-drill.sh 921 192.168.x.y --label "3. 完整還原" --failed-at 2026-10-02T03:10:00Z
```

還原工具自己分配 VMID 時（例如 HDP 的完整還原），VMID 填 `auto`，用 `--name` 依 VM 名稱找：

```sh
./restore-drill.sh auto 192.168.x.y --name myvm-recovered --label "3. 完整還原" --failed-at 2026-10-02T03:10:00Z
```

`qm` 只看得到本機節點的 VM，請在還原目標節點上執行，或設 `QM="ssh root@<節點> qm"`。

還原落在 PVE 以外，例如 HDP 的即時還原會把 VM 開在 NAS 的 Virtualization Station，這時加 `--no-pve`，跳過 `qm` 的兩步，VMID 欄位隨意填：

```sh
./restore-drill.sh vs 192.168.x.y --no-pve --label "1. 即時還原" --failed-at 2026-10-02T03:10:00Z
```

結束時印出一列表格，貼進 `drill-log.md`，JSONL 追加到 `drills.jsonl`（可用環境變數 `OUT` 換路徑）。

## 要讓 IP 可預期

`restore-drill.sh` 在已知的 IP 上等 ping。實測 HDP 即時還原出來的 VM 即使沿用原 MAC，DHCP 仍可能給另一個位址，這時腳本會一直等到逾時。要被演練或被即時還原接手的 VM，請設 DHCP 保留或靜態位址。Debian／Ubuntu cloud image 的做法是關掉 cloud-init 的網路設定，自己寫 netplan：

```sh
echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
# 再於 /etc/netplan/ 寫靜態位址，移走 50-cloud-init.yaml
```

## 客體時鐘

QNAP Virtualization Station 以本地時間提供 RTC，Linux 客體開機時會先快 8 小時（UTC+8），NTP 同步後才校正。`canary.sh verify` 會印出 NTP 同步狀態。還原點取的是最後一個斷層「之前」的那一筆，不受錯誤時間影響，但那一行斷層長度會是假的。

## 結束碼

`canary.sh verify`：0 找到還原點且 payload 正確，1 找不到斷層，2 payload 不符。

`restore-drill.sh`：0 演練通過，2 payload 不符，3 逾時（預設 1800 秒，`--timeout` 調整）。

## 測試

```sh
sh tests/fake-flow.sh
shellcheck canary.sh restore-drill.sh tests/fake-flow.sh
```

CI 在每次 push 跑這兩項。

## 授權

Apache-2.0
