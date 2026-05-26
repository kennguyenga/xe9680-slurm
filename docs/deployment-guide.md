# Slurm Deployment Guide — Dell PowerEdge XE9680 / RHEL

**Target:** Multi-node GPU HPC cluster for a Service Provider Common Cloud Platform
**Scope:** Controller + N× XE9680 compute nodes, GPU scheduling (GRES), multi-tenant accounting (slurmdbd)

> This guide reuses the exact architecture you validated on the VM lab
> (slurmctld + slurmd + Munge). The new pieces for XE9680/production are:
> **(1) GPU/GRES scheduling, (2) slurmdbd accounting, (3) production hardening.**

---

## 0. Architecture & assumptions

```
                +-------------------------+
                |   slurm-ctl (control)   |   <- separate, non-GPU node
                |   slurmctld + slurmdbd  |      runs controller + DB
                |   MariaDB                |      (login/submit host)
                +-----------+-------------+
                            | (6817 ctld, 6819 dbd, munge)
        +-------------------+-------------------+--------- ...
        |                   |                   |
+-------v-------+   +-------v-------+   +-------v-------+
|  xe9680-01    |   |  xe9680-02    |   |  xe9680-NN    |
|  slurmd       |   |  slurmd       |   |  slurmd       |
|  8x GPU       |   |  8x GPU       |   |  8x GPU       |
+---------------+   +---------------+   +---------------+
```

**Fill these in for your environment:**

| Item | Value |
|------|-------|
| Controller hostname / IP | `slurm-ctl` / `__________` |
| Compute node names | `xe9680-01 ... xe9680-NN` |
| Compute node IPs | `__________` |
| GPUs per node | 8 (XE9680 default: H100 or A100) |
| GPU model | `nvidia_h100` (adjust to your SKU) |
| Shared filesystem? (NFS/Lustre/GPFS) | `__________` |
| Cluster name | `commoncloud` |

---

## 1. Prerequisites on EVERY node (controller + all compute)

### 1.1 Consistent identity — the lesson from the lab
The #1 multi-node failure is the **SlurmUser UID/GID mismatch** (you hit this).
On a real cluster, solve it properly: create slurm with the SAME uid/gid
everywhere, or (better) source it from central identity (LDAP/SSSD/IdM).

```bash
# Pick a fixed, unused uid/gid and use it on ALL nodes (example: 990):
sudo groupadd -g 990 slurm
sudo useradd  -u 990 -g 990 -M -s /sbin/nologin -d /var/lib/slurm slurm
sudo groupadd -g 991 munge 2>/dev/null || true
sudo useradd  -u 991 -g 991 -M -s /sbin/nologin munge 2>/dev/null || true
```

Verify identical on all nodes:
```bash
id slurm    # uid/gid must match on controller AND every compute node
```

### 1.2 Time sync (Munge requires it)
```bash
sudo dnf install -y chrony
sudo systemctl enable --now chronyd
chronyc tracking      # confirm synced
```

### 1.3 Hostname resolution
Every node must resolve every other node by name. Use DNS, or /etc/hosts
identical on all nodes:
```
10.x.x.10  slurm-ctl
10.x.x.11  xe9680-01
10.x.x.12  xe9680-02
# ... etc
```

### 1.4 RHEL packages
On RHEL, Slurm typically comes from EPEL or OpenHPC, or you build from
SchedMD source RPMs. Recommended for production: build matching RPMs once,
install everywhere, so versions are identical (another lab lesson — version
skew breaks node registration).

```bash
# If using EPEL:
sudo dnf install -y epel-release
sudo dnf install -y munge munge-libs

# Controller node:
sudo dnf install -y slurm slurm-slurmctld slurm-slurmdbd mariadb-server

# Compute nodes:
sudo dnf install -y slurm slurm-slurmd
```

> Confirm the SAME slurm version on all nodes:  `rpm -q slurm`

---

## 2. Munge (cluster-wide shared key)

```bash
# On the CONTROLLER only — create the key:
sudo -u munge /usr/sbin/mungekey --verbose     # newer munge
sudo chown munge:munge /etc/munge/munge.key
sudo chmod 400 /etc/munge/munge.key

# Distribute the SAME key to every node (loop over your nodes):
for n in xe9680-01 xe9680-02 xe9680-NN; do
  sudo scp /etc/munge/munge.key root@$n:/etc/munge/munge.key
  ssh root@$n 'chown munge:munge /etc/munge/munge.key && chmod 400 /etc/munge/munge.key && systemctl enable --now munge'
done

# Start on controller too:
sudo systemctl enable --now munge

# Verify cross-node (run from controller to each compute):
munge -n | ssh xe9680-01 unmunge | grep STATUS   # expect Success (0)
```

---

## 3. Detect GPU topology on a compute node

On ONE xe9680 compute node, gather what Slurm needs:

```bash
# CPU/memory layout for the NodeName line:
slurmd -C

# GPU inventory:
nvidia-smi -L                       # lists the 8 GPUs
nvidia-smi topo -m                  # NVLink/affinity topology
ls -l /dev/nvidia[0-9]*             # device files for gres.conf
```

Record the GPU count (8) and device numbering. All XE9680 nodes should be
identical, so you configure once and apply to all.

---

## 4. Configuration files

All config files live in `/etc/slurm/` and must be IDENTICAL on every node
(controller + compute). Deploy once, copy everywhere.

### 4.1 `/etc/slurm/slurm.conf`

```ini
ClusterName=commoncloud
SlurmctldHost=slurm-ctl

AuthType=auth/munge
CredType=cred/munge

# --- Scheduling ---
SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_Core_Memory

# --- GPU support: declare GRES + GPU-aware accounting ---
GresTypes=gpu
AccountingStorageTRES=gres/gpu

# --- Process tracking & task launch (cgroup-based GPU isolation) ---
ProctrackType=proctrack/cgroup
TaskPlugin=task/affinity,task/cgroup

# --- Files, dirs, user ---
SlurmUser=slurm
SlurmctldPidFile=/var/run/slurmctld/slurmctld.pid
SlurmdPidFile=/var/run/slurmd/slurmd.pid
SlurmdSpoolDir=/var/spool/slurmd
StateSaveLocation=/var/spool/slurmctld

# --- Logging ---
SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdLogFile=/var/log/slurm/slurmd.log

# --- srun IO port range (lab lesson: open these in the firewall!) ---
SrunPortRange=60001-63000

# --- Behavior / resilience ---
ReturnToService=2
SlurmctldTimeout=120
SlurmdTimeout=300

# --- Accounting (slurmdbd) ---
AccountingStorageType=accounting_storage/slurmdbd
AccountingStorageHost=slurm-ctl
JobAcctGatherType=jobacct_gather/cgroup
JobAcctGatherFrequency=30

# --- Multi-tenant fair-share priority ---
PriorityType=priority/multifactor
PriorityDecayHalfLife=7-0
PriorityWeightFairshare=100000
PriorityWeightAge=1000
PriorityWeightPartition=10000
PriorityWeightQOS=1000000

# === NODES: one line per XE9680. Adjust CPUs/RealMemory to `slurmd -C`. ===
# 8 GPUs declared via Gres=gpu:8. RealMemory set below physical.
NodeName=xe9680-01 NodeAddr=10.x.x.11 CPUs=224 Sockets=2 CoresPerSocket=56 ThreadsPerCore=2 RealMemory=2000000 Gres=gpu:8 State=UNKNOWN
NodeName=xe9680-02 NodeAddr=10.x.x.12 CPUs=224 Sockets=2 CoresPerSocket=56 ThreadsPerCore=2 RealMemory=2000000 Gres=gpu:8 State=UNKNOWN
# ... add xe9680-NN ...

# === PARTITIONS ===
# A general GPU partition spanning all nodes. Add per-tenant or per-QOS
# partitions as your cloud design requires.
PartitionName=gpu Nodes=ALL Default=YES MaxTime=7-00:00:00 State=UP
```

> **Note:** CPUs/RealMemory above are PLACEHOLDERS. Use the real `slurmd -C`
> output from your XE9680 (CPU count and memory differ by SKU). Set
> RealMemory a few % below physical to avoid the "Low RealMemory" drain you
> saw in the lab.

### 4.2 `/etc/slurm/gres.conf` (GPU device mapping)

```ini
# Maps the gpu GRES to actual device files. AutoDetect simplifies this
# greatly if NVML is available (it is, with the NVIDIA driver installed).
AutoDetect=nvml

# If AutoDetect doesn't work on your build, declare explicitly:
# Name=gpu Type=h100 File=/dev/nvidia0
# Name=gpu Type=h100 File=/dev/nvidia1
# ... through /dev/nvidia7
```

### 4.3 `/etc/slurm/cgroup.conf`

```ini
CgroupPlugin=autodetect
ConstrainCores=yes
ConstrainRAMSpace=yes
ConstrainDevices=yes          # CRITICAL for GPU isolation between tenants
```

> `ConstrainDevices=yes` is what stops a job that requested 2 GPUs from
> touching the other 6 — essential for a multi-tenant cloud.

---

## 5. slurmdbd (accounting database)

### 5.1 MariaDB on the controller
```bash
sudo systemctl enable --now mariadb
sudo mysql_secure_installation        # set a root password

sudo mysql -u root -p <<'SQL'
CREATE DATABASE slurm_acct_db;
CREATE USER 'slurm'@'localhost' IDENTIFIED BY 'CHANGE_ME_STRONG_PASS';
GRANT ALL ON slurm_acct_db.* TO 'slurm'@'localhost';
FLUSH PRIVILEGES;
SQL
```

### 5.2 `/etc/slurm/slurmdbd.conf` (controller only, mode 600, owned by slurm)
```ini
AuthType=auth/munge
DbdHost=slurm-ctl
DbdPort=6819
SlurmUser=slurm
StorageType=accounting_storage/mysql
StorageHost=localhost
StorageUser=slurm
StoragePass=CHANGE_ME_STRONG_PASS
StorageLoc=slurm_acct_db
LogFile=/var/log/slurm/slurmdbd.log
PidFile=/var/run/slurmdbd/slurmdbd.pid
```
```bash
sudo chown slurm:slurm /etc/slurm/slurmdbd.conf
sudo chmod 600 /etc/slurm/slurmdbd.conf
sudo systemctl enable --now slurmdbd
```

### 5.3 Bootstrap the cluster + tenants in the accounting DB
```bash
sacctmgr add cluster commoncloud
# Per-tenant accounts (example):
sacctmgr add account tenant_a Description="Tenant A" Organization=cloud
sacctmgr add account tenant_b Description="Tenant B" Organization=cloud
# Associate users to tenant accounts:
sacctmgr add user alice Account=tenant_a
sacctmgr add user bob   Account=tenant_b
```

---

## 6. Directories, firewall, start order

### 6.1 Runtime dirs (all nodes; tmpfiles rule survives reboot)
```bash
# Controller:
echo 'd /var/run/slurmctld 0755 slurm slurm -' | sudo tee /etc/tmpfiles.d/slurmctld.conf
echo 'd /var/run/slurmdbd   0755 slurm slurm -' | sudo tee /etc/tmpfiles.d/slurmdbd.conf
# Compute:
echo 'd /var/run/slurmd     0755 root  root  -' | sudo tee /etc/tmpfiles.d/slurmd.conf
sudo systemd-tmpfiles --create

# All nodes:
sudo mkdir -p /var/spool/slurmctld /var/spool/slurmd /var/log/slurm
sudo chown slurm:slurm /var/spool/slurmctld /var/log/slurm
```

### 6.2 Firewall (lab lessons: open ctld, dbd, slurmd, AND srun IO range)
```bash
# Controller:
sudo firewall-cmd --permanent --add-port=6817/tcp   # slurmctld
sudo firewall-cmd --permanent --add-port=6819/tcp   # slurmdbd
sudo firewall-cmd --permanent --add-port=60001-63000/tcp  # srun IO
sudo firewall-cmd --reload

# Compute nodes:
sudo firewall-cmd --permanent --add-port=6818/tcp   # slurmd
sudo firewall-cmd --permanent --add-port=60001-63000/tcp
sudo firewall-cmd --reload

# Simpler for a trusted cluster network: mutually trust node IPs
# (use only on an isolated/management network):
# sudo firewall-cmd --permanent --zone=trusted --add-source=10.x.x.0/24
# sudo firewall-cmd --reload
```

### 6.3 Start order (matters)
```bash
# 1) munge everywhere (already running from step 2)
# 2) slurmdbd on controller
sudo systemctl enable --now slurmdbd
# 3) slurmctld on controller
sudo systemctl enable --now slurmctld
# 4) slurmd on each compute node
for n in xe9680-01 xe9680-02 xe9680-NN; do
  ssh root@$n 'systemctl enable --now slurmd'
done
```

---

## 7. Verify the cluster

```bash
sinfo -N -o "%N %c %m %G %t"      # %G shows GRES (gpu:8) per node
scontrol ping
sacctmgr show cluster              # accounting wired up?

# Nodes should be 'idle' with gpu:8 each. If any show drain/down:
scontrol show node xe9680-01 | grep -E "State|Reason|Gres"
```

---

## 8. GPU scheduling test scenarios

These are the NEW tests beyond your CPU lab suite — they validate the
GPU/multi-tenant layer specific to XE9680.

```bash
# 8.1 Allocate 1 GPU, confirm exactly 1 is visible (isolation works):
srun --gres=gpu:1 nvidia-smi -L            # should list ONE gpu
srun --gres=gpu:1 bash -c 'echo $CUDA_VISIBLE_DEVICES'

# 8.2 Allocate multiple GPUs on one node:
srun --gres=gpu:4 nvidia-smi -L            # lists 4

# 8.3 Full node (all 8 GPUs):
srun -N1 --gres=gpu:8 nvidia-smi -L        # lists 8

# 8.4 Multi-node GPU job (e.g. distributed training shape):
srun -N2 --gres=gpu:8 --ntasks-per-node=1 -l hostname

# 8.5 GPU contention — request more GPUs than one node has across jobs:
for i in 1 2 3; do
  sbatch --gres=gpu:8 --wrap="sleep 30; nvidia-smi -L"
done
squeue                                     # excess jobs queue (Resources)

# 8.6 Device isolation proof — a 1-GPU job must NOT see the others:
srun --gres=gpu:1 bash -c 'nvidia-smi -L | wc -l'   # expect 1, not 8

# 8.7 Per-tenant accounting (after running some jobs):
sacct -X --format=JobID,Account,AllocTRES%40,State
sreport cluster AccountUtilizationByUser    # per-tenant usage report
```

---

## 9. Multi-tenant / cloud-platform hardening (next layer)

For a Service Provider Common Cloud, once the above works, add:

- **QOS policies** — per-tenant limits on GPUs, job count, walltime
  (`sacctmgr add qos tenant_a_qos MaxTRESPerUser=gres/gpu=16 ...`).
- **Partitions per tenant or per SLA tier** — e.g. `gpu-prod`, `gpu-batch`,
  with different priorities/preemption.
- **Preemption** — let high-priority tenants preempt batch jobs
  (`PreemptType=preempt/qos`).
- **Limits & fair-share** — already enabled via priority/multifactor above;
  tune weights per your SLA model.
- **Pam_slurm_adm / cgroup** — restrict SSH to nodes where a user has a job.
- **High availability** — add a `SlurmctldHost` backup controller + shared
  StateSaveLocation on the cluster filesystem.
- **Prolog/Epilog scripts** — GPU health checks (DCGM), node clean-up
  between tenant jobs (scrub GPU memory, reset state).
- **NVIDIA DCGM + Slurm** — GPU health/telemetry integration.

---

## 10. Mapping back to your VM lab

| Lab concept (validated) | XE9680 production equivalent |
|---|---|
| 2 VMs, CPU-only | N× XE9680, 8 GPUs each |
| slurmctld on vm1 | dedicated control node |
| Munge cross-node auth | same — central key distribution |
| UID match fix (984) | central identity / fixed uid everywhere |
| firewall 6817/6818 + srun IO | same ports + dbd 6819 |
| CR_Core_Memory | + gres/gpu, ConstrainDevices |
| (skipped) accounting | slurmdbd + MariaDB + per-tenant accounts |
| CPU test suite | + GPU/GRES test scenarios (section 8) |

The control-plane architecture is identical to what you already debugged.
You are adding GPU scheduling and multi-tenant accounting on top of a
foundation you've already proven you can build and troubleshoot.
