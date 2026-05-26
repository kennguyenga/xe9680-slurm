# XE9680 Slurm Deployment

Slurm workload-manager deployment for a multi-node **Dell PowerEdge XE9680 / RHEL**
GPU cluster, built for a Service Provider Common Cloud Platform.

## What this covers

- Multi-node Slurm cluster (controller + 5–8 XE9680 compute nodes)
- **GPU scheduling** via GRES (8 GPUs per node, NVML autodetect, cgroup device isolation)
- **Multi-tenant accounting** via slurmdbd + MariaDB (per-tenant accounts, fair-share)
- Munge authentication, firewall, and production-hardening notes
- GPU-specific validation scenarios

## Contents

- [`docs/deployment-guide.md`](docs/deployment-guide.md) — full step-by-step deployment guide
- [`scripts/run_slurm_tests.sh`](scripts/run_slurm_tests.sh) — cluster validation test suite
- [`config/`](config/) — example slurm.conf, gres.conf, cgroup.conf, slurmdbd.conf

## Architecture

```
        slurm-ctl (controller: slurmctld + slurmdbd + MariaDB)
              |
   +----------+----------+-------- ...
   |          |          |
xe9680-01  xe9680-02  xe9680-NN   (slurmd, 8x GPU each)
```

## Status

Control-plane architecture validated on a 2-node lab; this repo extends it
to XE9680 GPU hardware with multi-tenant accounting. Configs contain
placeholders (IPs, CPU/memory from `slurmd -C`, GPU type) to fill per site.

## Notes

Config files contain **placeholder credentials** (e.g. `CHANGE_ME_STRONG_PASS`
in slurmdbd.conf). Replace before use and never commit real passwords.
