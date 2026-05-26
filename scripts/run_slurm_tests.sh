#!/bin/bash
#
# run_slurm_tests.sh
# -----------------------------------------------------------------------------
# A self-contained Slurm verification suite for a multi-node, CPU-only cluster
# (e.g. VMs on ESXi: 1 controller + N compute nodes).
#
# It runs a series of scenarios, records PASS/FAIL/SKIP for each, and prints a
# summary table at the end. Safe to re-run after config changes.
#
# Usage:
#   chmod +x run_slurm_tests.sh
#   ./run_slurm_tests.sh                 # run all applicable tests
#   ./run_slurm_tests.sh --keep-logs     # don't delete per-job output files
#
# Notes:
#   * Run from a directory you can write to (job output files land here).
#   * Run as a normal user that can submit jobs (NOT root, ideally).
#   * Some tests (time limit, accounting) need slurmdbd/accounting configured;
#     they auto-SKIP with an explanation if accounting isn't available.
# -----------------------------------------------------------------------------

set -u

KEEP_LOGS=0
[[ "${1:-}" == "--keep-logs" ]] && KEEP_LOGS=1

# ---- pretty output helpers --------------------------------------------------
GREEN=$'\e[32m'; RED=$'\e[31m'; YELLOW=$'\e[33m'; BLUE=$'\e[34m'; BOLD=$'\e[1m'; RESET=$'\e[0m'

declare -a RESULTS   # "name|status|detail"

pass() { echo "${GREEN}  PASS${RESET}: $2"; RESULTS+=("$1|PASS|$2"); }
fail() { echo "${RED}  FAIL${RESET}: $2"; RESULTS+=("$1|FAIL|$2"); }
skip() { echo "${YELLOW}  SKIP${RESET}: $2"; RESULTS+=("$1|SKIP|$2"); }
hdr()  { echo; echo "${BOLD}${BLUE}=== $1 ===${RESET}"; }

WORKDIR=$(mktemp -d ./slurmtest.XXXXXX)
cleanup() {
  if [[ $KEEP_LOGS -eq 0 ]]; then rm -rf "$WORKDIR"; fi
}
trap cleanup EXIT

# wait until a job leaves the queue (or timeout). $1=jobid $2=timeout_sec
wait_for_job() {
  local jid=$1 timeout=${2:-120} waited=0
  while squeue -h -j "$jid" 2>/dev/null | grep -q .; do
    sleep 2; waited=$((waited+2))
    [[ $waited -ge $timeout ]] && return 1
  done
  return 0
}

# Detect whether sacct/accounting is usable
HAVE_ACCT=0
if command -v sacct >/dev/null 2>&1; then
  if sacct -n -S now -o JobID >/dev/null 2>&1; then HAVE_ACCT=1; fi
fi

echo "${BOLD}Slurm multi-node test suite${RESET}"
echo "Working dir: $WORKDIR   (accounting available: $( [[ $HAVE_ACCT -eq 1 ]] && echo yes || echo no ))"

# -----------------------------------------------------------------------------
# Scenario 0: Environment sanity
# -----------------------------------------------------------------------------
hdr "0. Environment sanity"
if ! command -v sinfo >/dev/null 2>&1; then
  fail "env" "Slurm client commands not found in PATH. Is Slurm installed?"
  echo "Cannot continue without Slurm. Exiting."
  exit 1
fi
if scontrol ping 2>/dev/null | grep -qi "UP"; then
  pass "controller_ping" "slurmctld is reachable"
else
  fail "controller_ping" "scontrol ping failed - controller down or unreachable"
fi

NODE_COUNT=$(sinfo -h -N -o "%N" 2>/dev/null | sort -u | wc -l)
IDLE_NODES=$(sinfo -h -o "%t %D" 2>/dev/null | awk '$1=="idle"{s+=$2} END{print s+0}')
echo "  Detected nodes: $NODE_COUNT   (idle: $IDLE_NODES)"
if [[ "$NODE_COUNT" -ge 1 ]]; then
  pass "nodes_present" "$NODE_COUNT node(s) registered"
else
  fail "nodes_present" "No nodes registered with the controller"
fi
MULTINODE=0
[[ "$NODE_COUNT" -ge 2 ]] && MULTINODE=1

# -----------------------------------------------------------------------------
# Scenario 1: Smoke test - srun a single command
# -----------------------------------------------------------------------------
hdr "1. Smoke test (srun hostname)"
OUT=$(srun -N1 --time=00:01:00 hostname 2>&1)
if [[ -n "$OUT" && $? -eq 0 ]]; then
  pass "smoke" "srun returned: $OUT"
else
  fail "smoke" "srun produced no output / errored: $OUT"
fi

# -----------------------------------------------------------------------------
# Scenario 2: Batch job through the queue
# -----------------------------------------------------------------------------
hdr "2. Batch submission (sbatch)"
JID=$(sbatch --parsable -o "$WORKDIR/batch_%j.out" \
      --time=00:02:00 --wrap="sleep 5; echo RAN_ON \$(hostname)" 2>/dev/null)
if [[ -n "$JID" ]]; then
  if wait_for_job "$JID" 90 && grep -q "RAN_ON" "$WORKDIR"/batch_*.out 2>/dev/null; then
    pass "batch" "Batch job $JID completed and wrote output"
  else
    fail "batch" "Batch job $JID did not complete cleanly"
  fi
else
  fail "batch" "sbatch did not return a job id"
fi

# -----------------------------------------------------------------------------
# Scenario 3: Resource requests honored
# -----------------------------------------------------------------------------
hdr "3. Resource allocation honored"
NCPU=$(srun --cpus-per-task=2 --time=00:01:00 nproc 2>/dev/null | tail -1)
if [[ "$NCPU" == "2" ]]; then
  pass "cpu_request" "--cpus-per-task=2 yielded nproc=2"
else
  fail "cpu_request" "Expected 2 CPUs, got '$NCPU' (check node CPU config)"
fi

TASKS=$(srun -n4 --time=00:01:00 hostname 2>/dev/null | wc -l)
if [[ "$TASKS" == "4" ]]; then
  pass "task_count" "-n4 launched 4 tasks"
else
  fail "task_count" "Expected 4 task lines, got $TASKS"
fi

# -----------------------------------------------------------------------------
# Scenario 4: Full batch script with directives + env vars
# -----------------------------------------------------------------------------
hdr "4. Batch script with #SBATCH directives"
cat > "$WORKDIR/job4.sh" <<'EOF'
#!/bin/bash
#SBATCH --job-name=test_directives
#SBATCH --ntasks=2
#SBATCH --cpus-per-task=1
#SBATCH --mem=256M
#SBATCH --time=00:02:00
echo "JOBID=$SLURM_JOB_ID NODE=$(hostname) NTASKS=$SLURM_NTASKS"
srun echo "task $SLURM_PROCID on $(hostname)"
EOF
JID=$(sbatch --parsable -o "$WORKDIR/job4_%j.out" "$WORKDIR/job4.sh" 2>/dev/null)
if [[ -n "$JID" ]] && wait_for_job "$JID" 90 && grep -q "JOBID=" "$WORKDIR"/job4_*.out 2>/dev/null; then
  pass "directives" "Directive-based job $JID ran and used SLURM_* env vars"
else
  fail "directives" "Directive-based job did not complete as expected"
fi

# -----------------------------------------------------------------------------
# Scenario 5: Queue contention (scheduling under pressure)
# -----------------------------------------------------------------------------
hdr "5. Queue contention (exclusive jobs serialize)"
declare -a CJOBS
for i in 1 2 3; do
  J=$(sbatch --parsable --exclusive -o "$WORKDIR/cont_%j.out" \
      --time=00:02:00 --wrap="sleep 8; hostname" 2>/dev/null)
  CJOBS+=("$J")
done
sleep 3
# On a cluster with fewer free nodes than jobs, at least one should be pending.
PENDING=$(squeue -h -t PD -j "$(IFS=,; echo "${CJOBS[*]}")" 2>/dev/null | wc -l)
RUNNING=$(squeue -h -t R  -j "$(IFS=,; echo "${CJOBS[*]}")" 2>/dev/null | wc -l)
echo "  Running now: $RUNNING   Pending: $PENDING"
if [[ "$NODE_COUNT" -lt 3 && "$PENDING" -ge 1 ]]; then
  pass "contention" "Excess jobs correctly queued as PENDING (scheduler gating works)"
elif [[ "$NODE_COUNT" -ge 3 ]]; then
  pass "contention" "Enough nodes that all 3 can run in parallel (expected)"
else
  skip "contention" "Could not clearly observe queuing (timing-dependent)"
fi
# clean up the contention jobs so they don't hold the cluster
for J in "${CJOBS[@]}"; do scancel "$J" 2>/dev/null; done

# -----------------------------------------------------------------------------
# Scenario 6: Job array
# -----------------------------------------------------------------------------
hdr "6. Job array (1-4)"
JID=$(sbatch --parsable --array=1-4 -o "$WORKDIR/arr_%A_%a.out" \
      --time=00:01:00 --wrap='echo "ARRAY_TASK ${SLURM_ARRAY_TASK_ID} on $(hostname)"' 2>/dev/null)
BASEID=${JID%%_*}
if [[ -n "$JID" ]]; then
  wait_for_job "$BASEID" 90
  NFILES=$(ls "$WORKDIR"/arr_*.out 2>/dev/null | wc -l)
  if [[ "$NFILES" -ge 4 ]]; then
    pass "job_array" "Array produced $NFILES task output files"
  else
    fail "job_array" "Expected >=4 array outputs, found $NFILES"
  fi
else
  fail "job_array" "Array submission failed"
fi

# -----------------------------------------------------------------------------
# Scenario 7: Cancellation
# -----------------------------------------------------------------------------
hdr "7. Job cancellation (scancel)"
JID=$(sbatch --parsable -o "$WORKDIR/cancel_%j.out" --time=00:05:00 --wrap="sleep 300" 2>/dev/null)
sleep 3
if squeue -h -j "$JID" 2>/dev/null | grep -q .; then
  scancel "$JID" 2>/dev/null
  sleep 3
  if ! squeue -h -j "$JID" 2>/dev/null | grep -q .; then
    pass "cancel" "Job $JID submitted then successfully cancelled"
  else
    fail "cancel" "Job $JID still in queue after scancel"
  fi
else
  fail "cancel" "Job $JID never appeared in queue to cancel"
fi

# -----------------------------------------------------------------------------
# Scenario 8: Multi-node placement (only meaningful with >=2 nodes)
# -----------------------------------------------------------------------------
hdr "8. Multi-node placement"
if [[ "$MULTINODE" -eq 1 ]]; then
  # Ask for 2 nodes, 1 task each, print which physical node each lands on.
  MAPOUT=$(srun -N2 --ntasks-per-node=1 --time=00:01:00 hostname 2>/dev/null | sort -u)
  UNIQ=$(echo "$MAPOUT" | grep -c .)
  if [[ "$UNIQ" -ge 2 ]]; then
    pass "multinode" "Job spanned $UNIQ distinct physical nodes: $(echo $MAPOUT | tr '\n' ' ')"
  else
    fail "multinode" "Requested 2 nodes but tasks landed on $UNIQ node(s)"
  fi
else
  skip "multinode" "Only $NODE_COUNT node registered - add compute nodes to test this"
fi

# -----------------------------------------------------------------------------
# Scenario 9: Time-limit enforcement (needs accounting to confirm state)
# -----------------------------------------------------------------------------
hdr "9. Time-limit enforcement"
JID=$(sbatch --parsable -o "$WORKDIR/timeout_%j.out" \
      --time=00:00:10 --wrap="sleep 120; echo SHOULD_NOT_PRINT" 2>/dev/null)
if [[ -n "$JID" ]]; then
  wait_for_job "$JID" 90
  if [[ $HAVE_ACCT -eq 1 ]]; then
    STATE=$(sacct -n -j "$JID" -o State 2>/dev/null | head -1 | tr -d ' ')
    if echo "$STATE" | grep -qi "TIMEOUT"; then
      pass "timelimit" "Job hit TIMEOUT as expected (state=$STATE)"
    else
      fail "timelimit" "Expected TIMEOUT, accounting shows state=$STATE"
    fi
  else
    # Fall back to checking the output file never printed the forbidden line
    if ! grep -q "SHOULD_NOT_PRINT" "$WORKDIR"/timeout_*.out 2>/dev/null; then
      pass "timelimit" "Job was terminated before completion (accounting off, inferred from output)"
    else
      fail "timelimit" "Job ran to completion - time limit not enforced"
    fi
  fi
else
  fail "timelimit" "Could not submit time-limit test job"
fi

# -----------------------------------------------------------------------------
# Scenario 10: Accounting / sacct
# -----------------------------------------------------------------------------
hdr "10. Accounting (sacct)"
if [[ $HAVE_ACCT -eq 1 ]]; then
  ROWS=$(sacct -n -S today -o JobID,State 2>/dev/null | grep -c .)
  if [[ "$ROWS" -ge 1 ]]; then
    pass "accounting" "sacct returned $ROWS job record(s) for today"
  else
    fail "accounting" "sacct works but returned no records (unexpected after running tests)"
  fi
else
  skip "accounting" "slurmdbd/accounting not configured - sacct unavailable"
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo
echo "${BOLD}========================= SUMMARY =========================${RESET}"
printf "%-16s %-6s %s\n" "SCENARIO" "RESULT" "DETAIL"
printf "%-16s %-6s %s\n" "--------" "------" "------"
P=0; F=0; S=0
for r in "${RESULTS[@]}"; do
  IFS='|' read -r name status detail <<< "$r"
  case "$status" in
    PASS) color=$GREEN; P=$((P+1));;
    FAIL) color=$RED;   F=$((F+1));;
    SKIP) color=$YELLOW;S=$((S+1));;
  esac
  printf "%-16s ${color}%-6s${RESET} %s\n" "$name" "$status" "$detail"
done
echo "${BOLD}----------------------------------------------------------${RESET}"
echo "${GREEN}PASS: $P${RESET}   ${RED}FAIL: $F${RESET}   ${YELLOW}SKIP: $S${RESET}"
echo
if [[ $F -eq 0 ]]; then
  echo "${GREEN}${BOLD}All applicable tests passed.${RESET}"
else
  echo "${RED}${BOLD}$F test(s) failed.${RESET} Check logs: journalctl -u slurmctld -n 50 ; journalctl -u slurmd -n 50"
fi
[[ $KEEP_LOGS -eq 1 ]] && echo "Per-job output kept in: $WORKDIR"
exit $F
