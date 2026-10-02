#!/usr/bin/env bash
# Fork-only capture for NVIDIA/OpenShell#3840. Not part of the patch.
#
# Runs inside e2e/with-docker-gateway.sh, which exports OPENSHELL_BIN and
# OPENSHELL_GATEWAY. Writes everything under $CAPTURE_DIR.
#
# Phase A (clean scenario, sandbox "policygen"):
#   1. GET https://api.github.com/zen under the quickstart policy   -> allowed
#   2. DELETE /repos/acme/app under the quickstart read-only preset -> denied (L7)
#   3. policy set to the restrictive default (hot reload)           -> CONFIG:LOADED
#   4. GET https://api.github.com/zen after the reload              -> denied
#
# Phase B (race probe, sandbox "policygen-race"): the same reload while curl
# runs in a tight loop inside the sandbox. No artificial delays are added to
# OpenShell; this only looks for a decision under the new generation that is
# written before the CONFIG:LOADED event for that generation.

set -uo pipefail

OS="${OPENSHELL_BIN:?OPENSHELL_BIN must be set}"
OUT="${CAPTURE_DIR:?CAPTURE_DIR must be set}"
mkdir -p "${OUT}"
STEPS="${OUT}/steps.log"
: >"${STEPS}"

QUICKSTART="examples/sandbox-policy-quickstart/policy.yaml"

note() { printf '\n== [%s] %s\n' "$(date -u +%H:%M:%S.%3N)" "$*" | tee -a "${STEPS}"; }
run() {
  printf '+ %s\n' "$*" | tee -a "${STEPS}"
  "$@" 2>&1 | tee -a "${STEPS}"
  local rc=${PIPESTATUS[0]}
  printf '  (exit %s)\n' "${rc}" | tee -a "${STEPS}"
  return "${rc}"
}
sx() {
  local name=$1
  shift
  run "${OS}" sandbox exec --name "${name}" --no-tty --no-login-shell -- "$@"
}

# The literal restrictive default from openshell-policy::restrictive_default_policy().
cat >"${OUT}/restrictive-default.yaml" <<'EOF'
version: 1
filesystem_policy:
  include_workdir: true
  read_only: [/bin, /usr, /lib, /proc, /dev/urandom, /etc, /var/log]
  read_write: [/tmp, /dev/null]
landlock:
  compatibility: best_effort
EOF

# Fallback if the gateway rejects dropping /app and /sandbox from a live
# sandbox: quickstart filesystem, no network policies. Network behaviour is the
# same as the restrictive default.
cat >"${OUT}/quickstart-no-network.yaml" <<'EOF'
version: 1
filesystem_policy:
  include_workdir: true
  read_only: [/bin, /usr, /lib, /proc, /dev/urandom, /app, /etc, /var/log]
  read_write: [/sandbox, /tmp, /dev/null]
landlock:
  compatibility: best_effort
EOF

reload_to_restrictive() {
  local name=$1
  if run "${OS}" policy set "${name}" --policy "${OUT}/restrictive-default.yaml" --wait --timeout 90; then
    echo "restrictive-default.yaml" >"${OUT}/${name}.reload-policy"
    return 0
  fi
  note "restrictive default rejected for ${name}; falling back to quickstart filesystem with no network policies"
  if run "${OS}" policy set "${name}" --policy "${OUT}/quickstart-no-network.yaml" --wait --timeout 90; then
    echo "quickstart-no-network.yaml" >"${OUT}/${name}.reload-policy"
    return 0
  fi
  echo "none" >"${OUT}/${name}.reload-policy"
  return 1
}

collect() {
  local name=$1
  note "collecting logs for ${name}"
  "${OS}" sandbox exec --name "${name}" --no-tty --no-login-shell -- \
    sh -c 'ls -la /var/log/; for f in /var/log/openshell-ocsf.*.log; do echo "### $f"; cat "$f"; done' \
    >"${OUT}/${name}.ocsf-via-exec.txt" 2>&1 || true
  "${OS}" sandbox exec --name "${name}" --no-tty --no-login-shell -- \
    sh -c 'for f in /var/log/openshell.*.log /var/log/openshell.log; do [ -f "$f" ] && { echo "### $f"; cat "$f"; }; done' \
    >"${OUT}/${name}.shorthand-file-via-exec.txt" 2>&1 || true
  "${OS}" logs "${name}" -n 5000 --since 2h >"${OUT}/${name}.openshell-logs.txt" 2>&1 || true
  "${OS}" policy list "${name}" >"${OUT}/${name}.policy-list.txt" 2>&1 || true
  "${OS}" policy get "${name}" --full >"${OUT}/${name}.policy-get.txt" 2>&1 \
    || "${OS}" policy get "${name}" >"${OUT}/${name}.policy-get.txt" 2>&1 || true

  # The Docker driver runs the supervisor in its own container with a
  # read-only rootfs and /var/log on tmpfs, so neither `sandbox exec` nor
  # `docker cp` can see the OCSF file. The runner is the Docker host, so read
  # it through the supervisor process's root.
  local ids id role pid dest
  ids=$(docker ps -q --filter "label=openshell.ai/sandbox-name=${name}" 2>/dev/null || true)
  for id in ${ids}; do
    role=$(docker inspect "${id}" --format '{{index .Config.Labels "openshell.ai/isolation-role"}}' 2>/dev/null || echo unknown)
    pid=$(docker inspect "${id}" --format '{{.State.Pid}}' 2>/dev/null || echo 0)
    dest="${OUT}/${name}.${role:-unknown}-var-log"
    mkdir -p "${dest}"
    docker inspect "${id}" --format '{{json .Config.Labels}}' >"${dest}/labels.json" 2>&1 || true
    if [ "${pid}" != "0" ]; then
      sudo sh -c "ls -la /proc/${pid}/root/var/log/" >"${dest}/ls.txt" 2>&1 || true
      for f in $(sudo sh -c "ls /proc/${pid}/root/var/log/ 2>/dev/null" | grep '^openshell'); do
        sudo cat "/proc/${pid}/root/var/log/${f}" >"${dest}/${f}" 2>/dev/null || true
      done
      sudo chown -R "$(id -u):$(id -g)" "${dest}" 2>/dev/null || true
    fi
  done
}

# A long-running workload keeps the sandbox Ready; `-- echo` would complete it.
create_sandbox() {
  local name=$1 i
  run "${OS}" sandbox create --name "${name}" --policy "${QUICKSTART}" \
    --no-auto-providers --no-tty --detach -- sh -c "exec sleep infinity" || return 1
  for i in $(seq 1 60); do
    if "${OS}" sandbox exec --name "${name}" --no-tty --no-login-shell -- true >/dev/null 2>&1; then
      note "${name} ready after ~$((i * 2))s"
      return 0
    fi
    sleep 2
  done
  note "${name} did not become ready"
  run "${OS}" sandbox get "${name}"
  return 1
}

note "variant: ${CAPTURE_VARIANT:-unknown}  commit: $(git rev-parse HEAD)"
run "${OS}" --version

note "enable OCSF JSON export globally"
run "${OS}" settings set --global --key ocsf_json_enabled --value true --yes

# ---------------------------------------------------------------- Phase A
note "A: create sandbox policygen with the quickstart policy"
create_sandbox policygen || exit 1

# The setting is applied on the supervisor's next poll (10 s by default).
note "A: wait for the settings poll so JSON export is on"
sleep 25
sx policygen sh -c 'ls -la /var/log/'

note "A1: GET https://api.github.com/zen (expect allowed)"
sx policygen curl -sS --max-time 20 https://api.github.com/zen

note "A2: DELETE https://api.github.com/repos/acme/app (expect L7 deny)"
sx policygen curl -sS --max-time 20 -o /dev/null -w 'http_code=%{http_code}\n' \
  -X DELETE https://api.github.com/repos/acme/app

note "A3: hot reload policygen to the restrictive default"
reload_to_restrictive policygen

note "A4: GET https://api.github.com/zen after reload (expect denied)"
sx policygen curl -sS --max-time 20 https://api.github.com/zen

sleep 5
collect policygen

# ---------------------------------------------------------------- Phase B
note "B: create sandbox policygen-race with the quickstart policy"
if create_sandbox policygen-race; then
  sleep 25
  note "B: start a curl loop inside the sandbox, then reload while it runs"
  "${OS}" sandbox exec --name policygen-race --no-tty --no-login-shell -- \
    sh -c 'i=0; while [ $i -lt 300 ]; do curl -s -o /dev/null --max-time 3 https://api.github.com/zen; i=$((i+1)); done' \
    >"${OUT}/policygen-race.loop.txt" 2>&1 &
  LOOP_PID=$!
  sleep 8
  note "B: reload policygen-race to the restrictive default during the loop"
  reload_to_restrictive policygen-race
  wait "${LOOP_PID}" || true
  sleep 5
  collect policygen-race
else
  note "B: sandbox create failed; race probe skipped"
fi

note "done"
exit 0
