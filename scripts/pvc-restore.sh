#!/usr/bin/env bash
# Ad hoc PVC restore: counterpart to pvc-backup.sh. Scale a Deployment to 0,
# mount its PVC read-write in a throwaway pod, wipe the PVC contents, untar a
# local backup file into it, fix ownership to match the app's securityContext,
# delete the throwaway pod, then scale the Deployment back to its original
# replica count.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: pvc-restore.sh -n NAMESPACE -d DEPLOYMENT -f TARBALL [-p PVC_NAME] [-k CONTEXT] [-u UID] [-g GID] [-W] [-y]

  -n  Namespace (required)
  -d  Deployment name (required)
  -f  Path to the tarball produced by pvc-backup.sh (required)
  -p  PVC claim name (optional; auto-detected if the Deployment mounts exactly one PVC)
  -k  kubectl context to use (default: current context)
  -u  UID to chown restored files to (optional; auto-detected from the Deployment's securityContext)
  -g  GID to chown restored files to (optional; auto-detected from the Deployment's securityContext)
  -W  Do NOT wipe existing PVC contents before restoring (default: wipe first)
  -y  Skip the confirmation prompt

Example:
  ./pvc-restore.sh -n home -d vaultwarden -f ~/backups/old-cluster/vaultwarden-vaultwarden-20260803T115041.tar.gz
EOF
}

NAMESPACE=""
DEPLOYMENT=""
PVC=""
TARBALL=""
CONTEXT=""
UID_OVERRIDE=""
GID_OVERRIDE=""
WIPE=1
ASSUME_YES=0

while getopts "n:d:f:p:k:u:g:Wyh" opt; do
  case "$opt" in
    n) NAMESPACE="$OPTARG" ;;
    d) DEPLOYMENT="$OPTARG" ;;
    f) TARBALL="$OPTARG" ;;
    p) PVC="$OPTARG" ;;
    k) CONTEXT="$OPTARG" ;;
    u) UID_OVERRIDE="$OPTARG" ;;
    g) GID_OVERRIDE="$OPTARG" ;;
    W) WIPE=0 ;;
    y) ASSUME_YES=1 ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done

if [[ -z "$NAMESPACE" || -z "$DEPLOYMENT" || -z "$TARBALL" ]]; then
  usage
  exit 1
fi

if [[ ! -f "$TARBALL" ]]; then
  echo "Tarball not found: $TARBALL" >&2
  exit 1
fi
TARBALL="$(cd "$(dirname "$TARBALL")" && pwd)/$(basename "$TARBALL")"

KCTL=(kubectl)
[[ -n "$CONTEXT" ]] && KCTL=(kubectl --context "$CONTEXT")

"${KCTL[@]}" -n "$NAMESPACE" get deployment "$DEPLOYMENT" >/dev/null

if [[ -z "$PVC" ]]; then
  mapfile -t pvcs < <("${KCTL[@]}" -n "$NAMESPACE" get deployment "$DEPLOYMENT" \
    -o jsonpath='{.spec.template.spec.volumes[*].persistentVolumeClaim.claimName}' \
    | tr ' ' '\n' | grep -v '^$')
  if [[ ${#pvcs[@]} -eq 0 ]]; then
    echo "No PVC found on deployment/$DEPLOYMENT; pass one explicitly with -p" >&2
    exit 1
  elif [[ ${#pvcs[@]} -gt 1 ]]; then
    echo "Multiple PVCs found on deployment/$DEPLOYMENT (${pvcs[*]}); pass one with -p" >&2
    exit 1
  fi
  PVC="${pvcs[0]}"
fi

# Auto-detect the app's runAsUser/runAsGroup so restored files come out
# owned correctly, falling back to pod-level securityContext, then root.
if [[ -z "$UID_OVERRIDE" ]]; then
  UID_OVERRIDE=$("${KCTL[@]}" -n "$NAMESPACE" get deployment "$DEPLOYMENT" -o json | python3 -c '
import json, sys
d = json.load(sys.stdin)["spec"]["template"]["spec"]
pod_sc = d.get("securityContext", {})
uid = pod_sc.get("runAsUser")
if uid is None:
    for c in d.get("containers", []):
        uid = c.get("securityContext", {}).get("runAsUser")
        if uid is not None:
            break
print(uid if uid is not None else 0)
')
fi
if [[ -z "$GID_OVERRIDE" ]]; then
  GID_OVERRIDE=$("${KCTL[@]}" -n "$NAMESPACE" get deployment "$DEPLOYMENT" -o json | python3 -c '
import json, sys
d = json.load(sys.stdin)["spec"]["template"]["spec"]
pod_sc = d.get("securityContext", {})
gid = pod_sc.get("fsGroup", pod_sc.get("runAsGroup"))
if gid is None:
    for c in d.get("containers", []):
        gid = c.get("securityContext", {}).get("runAsGroup")
        if gid is not None:
            break
print(gid if gid is not None else 0)
')
fi

ORIG_REPLICAS=$("${KCTL[@]}" -n "$NAMESPACE" get deployment "$DEPLOYMENT" -o jsonpath='{.spec.replicas}')
[[ -z "$ORIG_REPLICAS" ]] && ORIG_REPLICAS=1

POD="pvc-restore-${DEPLOYMENT}-$$"

if [[ "$ASSUME_YES" != "1" ]]; then
  echo "About to scale deployment/$DEPLOYMENT (namespace $NAMESPACE${CONTEXT:+, context $CONTEXT}) to 0,"
  if [[ "$WIPE" == "1" ]]; then
    echo "WIPE existing contents of PVC $PVC,"
  fi
  echo "restore $TARBALL into it (chown ${UID_OVERRIDE}:${GID_OVERRIDE}),"
  echo "then scale back to $ORIG_REPLICAS replica(s)."
  read -r -p "Continue? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }
fi

CLEANED_UP=0
cleanup() {
  [[ "$CLEANED_UP" == "1" ]] && return
  CLEANED_UP=1
  echo "Cleaning up..."
  "${KCTL[@]}" -n "$NAMESPACE" delete pod "$POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  echo "Scaling deployment/$DEPLOYMENT back to $ORIG_REPLICAS replica(s)..."
  "${KCTL[@]}" -n "$NAMESPACE" scale deployment "$DEPLOYMENT" --replicas="$ORIG_REPLICAS" >/dev/null
}
trap cleanup EXIT INT TERM

echo "Scaling deployment/$DEPLOYMENT to 0 (was $ORIG_REPLICAS)..."
"${KCTL[@]}" -n "$NAMESPACE" scale deployment "$DEPLOYMENT" --replicas=0

echo "Waiting for pods to terminate..."
SELECTOR=$("${KCTL[@]}" -n "$NAMESPACE" get deployment "$DEPLOYMENT" -o json \
  | python3 -c 'import json,sys; d=json.load(sys.stdin)["spec"]["selector"]["matchLabels"]; print(",".join(f"{k}={v}" for k,v in d.items()))')
"${KCTL[@]}" -n "$NAMESPACE" wait --for=delete pod -l "$SELECTOR" --timeout=120s 2>/dev/null || true

echo "Starting restore pod (mounts PVC $PVC read-write)..."
cat <<EOF | "${KCTL[@]}" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $POD
  namespace: $NAMESPACE
  labels:
    app: pvc-restore
spec:
  restartPolicy: Never
  containers:
    - name: restore
      image: alpine:3.20
      command: ["sleep", "3600"]
      volumeMounts:
        - name: data
          mountPath: /restore
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: $PVC
EOF

echo "Waiting for restore pod to be ready..."
"${KCTL[@]}" -n "$NAMESPACE" wait --for=condition=Ready "pod/$POD" --timeout=120s

if [[ "$WIPE" == "1" ]]; then
  echo "Wiping existing contents of $PVC..."
  "${KCTL[@]}" -n "$NAMESPACE" exec "$POD" -- sh -c 'find /restore -mindepth 1 -delete'
fi

echo "Streaming $TARBALL into $PVC..."
"${KCTL[@]}" -n "$NAMESPACE" exec -i "$POD" -- tar xzf - -C /restore < "$TARBALL"

echo "Fixing ownership to ${UID_OVERRIDE}:${GID_OVERRIDE}..."
"${KCTL[@]}" -n "$NAMESPACE" exec "$POD" -- chown -R "${UID_OVERRIDE}:${GID_OVERRIDE}" /restore

echo "Restore complete."
