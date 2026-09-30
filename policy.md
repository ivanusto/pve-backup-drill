# HDP for Business 備份原則（Proxmox VE 叢集）

適用版本：HDP for Business Beta 1.0.0.6192（build 20260915）搭配 HDP for PC/VM 2.4.1.1084、QuTS hero h6.0.2.3591、Proxmox VE 9.2。正式版釋出後，本表逐項重驗。

## 備份對象

| 對象 | 磁碟所在 | HDP 備份 | 理由 |
|---|---|---|---|
| 叢集上的 VM | NAS 的 NFS | 是，逐台列入 | HDP 以 root 經 SSH 連上叢集 |
| 叢集上的 LXC 容器 | NAS 的 NFS | **無法** | HDP 的清單只列 VM，容器不在保護範圍內，列為缺口 |
| QDevice VM | NAS 本機（Virtualization Station） | 否 | 無狀態，十分鐘重建（Day 15） |
| PVE 節點本身 | 節點本機 | 否 | 以 Day 11 基線重灌，`/etc/pve` 由叢集同步 |

自動保護規則會把 Hypervisor 下所有 VM 自動收進指定原則。這個場域不使用規則，正式 VM 逐台指定原則。規則的 `enabled` 欄位經 API 送出後會被靜默忽略，要停用只能逐一停用 Workload。

## 原則設定

| 項目 | 值 | 依據 |
|---|---|---|
| 原則類型 | 不可變 | 建立後不能改回一般原則 |
| 排程 | 每日 01:30，第一次完整、之後增量 | 避開 NAS 本身的 01:00 記憶體釋放、02:00 `qfstrim`、03:00 惡意程式掃描與 `vs_refresh` |
| 保留 | 30 天（每日一版） | 不可變原則只能以天數保留，改成版本數會被靜默忽略；30 天涵蓋一個月的變更單回溯（Day 26） |
| 不可變期間 | 30 天 | 與保留相同，每個版本寫入後鎖 30 天 |
| 備份驗證 | 開，120 秒 | 開機影片作為 Day 27 的稽核證據；影片實際長度與設定值不同，要逐次看驗證工作結果 |
| Airgap+ | 不啟用 | 備份伺服器與 VM 的 NFS、QDevice 是同一台 NAS，排程關機等於整個叢集停擺 |
| 異地副本 | 預留 | Day 18 接手 |
| 觸發頻率上限 | 不適用 | 只存在於實體機器的原則，VM 原則沒有這個設定 |

## 實測到的邊界（本場域，2026-09-30）

- 完整備份讀取的是配置容量，不是使用量：32 GiB 磁碟、客體用 3 GB，讀 32.75 GB，107 MB/s。
- qcow2 在兩次備份之間關機，下一次仍是增量，dirty bitmap 以持久化 bitmap 存在 qcow2 檔內（`qemu-img info` 可見）。官方 FAQ 說 raw 與 vmdk 會退回完整備份，本場域未測 raw。
- 本機不可變只鎖該版本新寫入的檔案（atime 設為到期時間）。與舊資料去重共用的 pack、儲存庫的 `config`、`keys/` 與舊 index 仍是可寫檔案。
- 四次自動驗證前兩次成功，第 3、4 次在 4 秒內以「Virtualization Station is not responding」失敗，同一時段的即時還原與轉為永久都成功。驗證結果要逐次收進稽核軌跡。
- 完整還原的速率（約 64 MB/s）低於備份讀取（107 MB/s），估算 RTO 要用還原速率。
- 完整還原出來的 VM，cloud-init 光碟仍引用原 VM 的磁碟。
- 排程備份曾因 HDP for PC/VM 的 API 回 500 而失敗，工作沒有進到 Bareos。證據以 Bareos 工作紀錄與還原演練為準，不以主控台狀態為準。
- 即時還原的 VM 開在 NAS 的 Virtualization Station，沿用原 MAC 仍可能拿到不同的 DHCP 位址；要被接手的 VM 請用靜態位址或 DHCP 保留。
- 單一站台最多 4 台伺服器，不支援 QTS 與 ARM。
