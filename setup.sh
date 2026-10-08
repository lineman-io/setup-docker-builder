#!/usr/bin/env bash
# runners.io setup-docker-builder (RUN-109): what the one line does.
#
# On a runners.io runner that offers this job a layer cache:
#   1. checks the cache is really there -- configured, credentialled, answering
#   2. picks a builder that can export a registry cache and makes it the one
#      every later step uses: the DEFAULT builder on a containerd image store
#      (the fleet's guests, Docker Desktop), which also sees images an earlier
#      step built; a docker-container builder only on a legacy store, whose
#      docker driver cannot export one (RUN-617, section 3)
#   3. installs docker-buildx-shim.sh so builds that name no cache get this one
#   4. publishes the ref as outputs, for anyone wiring it by hand
#
# Anywhere else it does NOTHING and says so in one notice. "Anywhere else"
# includes a runners.io job whose cache is unreachable: a job without a layer
# cache builds correctly and more slowly, so every failure below degrades to
# that, never to a failed step. Everything that can refuse is checked BEFORE
# anything is changed, so "nothing was set up" is true when the notice says it.
#
# NOTHING HERE NAMES A HOST OR A PORT. The host comes from GHWARP_LAYER_CACHE,
# which the guest bootstrap sets from what the node handed this job, and that is
# the only place that knows which door this job can reach: the guest service
# port on metal (a guest's packets to its host on :443 are dropped by vmnet --
# WARP-271), the public :443 door on a burst VM (RUN-435). A port written here
# would be right for one of them and silently wrong for the other.
#
# The credential is the per-job token the bootstrap wrote into
# ~/.docker/config.json; this script checks it is THERE and never prints it.

set -euo pipefail

builder="runners-io"
dockercfg="${DOCKER_CONFIG:-$HOME/.docker}"
plugdir="${dockercfg}/cli-plugins"
statedir="${plugdir}/.runners-io"
marker="# runners.io setup-docker-builder: the docker-buildx shim"
automatic="${INPUT_AUTOMATIC:-true}"
key_in="${INPUT_KEY:-}"
out="${GITHUB_OUTPUT:-/dev/null}"
here="${GITHUB_ACTION_PATH:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

off() {
  # The no-op: one notice, empty outputs. An empty cache-from or cache-to handed
  # to docker/build-push-action means "no cache", so a workflow that wires the
  # outputs by hand stays correct here too.
  echo "::notice title=runners.io layer cache::$1 Nothing was set up; Docker builds in this job run exactly as they would without this step."
  {
    echo "enabled=false"
    echo "builder="
    echo "ref="
    echo "cache-from="
    echo "cache-to="
  } >>"$out"
  exit 0
}

# --- 1. is there a layer cache, really -------------------------------------
case "$automatic" in
  true | false) ;;
  *) off "automatic is '${automatic}'; it must be 'true' or 'false'." ;;
esac

host="${GHWARP_LAYER_CACHE:-}"
[ -n "$host" ] || off "This is not a runners.io runner, or this job was offered no layer cache."
if ! [[ "$host" =~ ^[A-Za-z0-9.-]+(:[0-9]+)?$ ]]; then
  off "GHWARP_LAYER_CACHE is '${host}', which is not a bare host[:port] and cannot start a registry reference."
fi

# HALF A CONFIGURATION is the case worth a sentence: a host with no credential
# is a build where every cache export is refused, which looks like a cache that
# does nothing.
auth=""
if [ -r "${dockercfg}/config.json" ]; then
  auth="$(jq -r --arg h "$host" '.auths[$h].auth // empty' "${dockercfg}/config.json" 2>/dev/null || true)"
fi
[ -n "$auth" ] || off "The layer cache is ${host} but ${dockercfg}/config.json holds no credential for it."

# Does it answer, with this credential? /v2/ is the registry's own probe and is
# behind authentication, so 200 means reachable AND accepted. The credential
# goes to curl on stdin, never in argv.
code="$(printf 'url = "https://%s/v2/"\nheader = "Authorization: Basic %s"\n' "$host" "$auth" |
  curl -sS -o /dev/null -w '%{http_code}' --max-time 15 -K - 2>/dev/null)" || true
[ "$code" = "200" ] || off "The layer cache at ${host} answered '${code:-nothing}' to an authenticated /v2/, not 200."

docker buildx version >/dev/null 2>&1 || off "docker buildx is not installed on this runner."

# --- 2. the reference -------------------------------------------------------
# The NAME is the repository's, and the tenant is not in it: the registry takes
# the tenant from the job token, never from the URL (internal/layercache). So
# two same-named repositories in different accounts are two namespaces, and a
# name that is another account's reaches only your own. It is what a log reads.
repo="${GITHUB_REPOSITORY:-cache}"
name="$(printf '%s' "${repo##*/}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | tr -s '-')"
name="${name#-}"
name="${name%-}"
[ -n "$name" ] || name="cache"

# The KEY is the tag, so the OCI grammar [A-Za-z0-9_][A-Za-z0-9._-]{0,127}.
# Empty means the shim derives one per image (see docker-buildx-shim.sh).
key=""
if [ -n "$key_in" ]; then
  key="$(printf '%s' "$key_in" | tr -c 'A-Za-z0-9._-' '-')"
  key="${key#"${key%%[A-Za-z0-9_]*}"}"
  key="${key:0:128}"
  [ -n "$key" ] || off "The key '${key_in}' has nothing left once made a valid tag."
fi

# --- 3. the builder ---------------------------------------------------------
# WHICH BUILDER DEPENDS ON THE IMAGE STORE (RUN-617).
#
# With the containerd image store (the fleet's guests, and Docker Desktop), the
# DEFAULT docker driver does everything we need: it exports a registry cache
# (the legacy overlay2 store could not, which is the only reason this action
# ever reached for a container-driver builder), and it builds FROM an image an
# earlier step in the same job produced -- because it IS the daemon's store. So
# on a containerd-store daemon we use the default builder: the cache works and a
# same-job `FROM my-local-base` keeps working. Verified against a real daemon.
#
# With the legacy store the default driver cannot export a registry cache, so we
# fall back to a docker-container builder (default-load=true, so `docker build
# -t x . && docker run x` still works). That builder has its own BuildKit and
# cannot see the daemon's image store, so a build FROM a same-job local image
# must run on the default driver instead -- which the shim detects and does,
# without the cache; see docker-buildx-shim.sh.
store="$(docker info --format '{{range .DriverStatus}}{{if eq (index . 0) "driver-type"}}{{index . 1}}{{end}}{{end}}' 2>/dev/null || true)"
case "$store" in
  *containerd.snapshotter*)
    builder="default"
    docker buildx use default >/dev/null 2>&1 || true
    ;;
  *)
    builder="runners-io"
    if docker buildx inspect "$builder" >/dev/null 2>&1; then
      docker buildx use "$builder"
    elif ! docker buildx create --name "$builder" --driver docker-container \
      --driver-opt default-load=true --use >/dev/null; then
      off "Creating a docker-container builder failed."
    fi
    if ! docker buildx inspect --bootstrap "$builder" >/dev/null; then
      docker buildx rm "$builder" >/dev/null 2>&1 || true
      off "The docker-container builder would not start, so it was removed."
    fi
    ;;
esac

# --- 4. the shim ------------------------------------------------------------
if [ "$automatic" = "true" ]; then
  mkdir -p "$statedir"
  real=""
  if [ -f "${plugdir}/docker-buildx" ] && grep -qF "$marker" "${plugdir}/docker-buildx"; then
    # Run twice in one job: the shim is already ours, and knows the real one.
    real="$(sed -n 's/^REAL_BUILDX=//p' "${statedir}/shim.conf" 2>/dev/null | head -1)"
  else
    real="$(docker info --format '{{range .ClientInfo.Plugins}}{{if eq .Name "buildx"}}{{.Path}}{{end}}{{end}}' 2>/dev/null || true)"
    if [ -n "$real" ] && [ "$real" = "${plugdir}/docker-buildx" ]; then
      # A buildx in the user directory (docker/setup-buildx-action puts one
      # there when asked for a version) is the one Docker runs; the shim takes
      # its place and hands to IT, not to an older system one behind it.
      mv "${plugdir}/docker-buildx" "${statedir}/docker-buildx"
      real="${statedir}/docker-buildx"
    fi
  fi
  if [ -z "$real" ] || [ ! -x "$real" ]; then
    docker buildx rm "$builder" >/dev/null 2>&1 || true
    off "Could not find the docker-buildx plugin binary to hand builds to."
  fi

  {
    echo "REAL_BUILDX=${real}"
    echo "CACHE_HOST=${host}"
    echo "CACHE_NAME=${name}"
    echo "BUILDER=${builder}"
    echo "KEY=${key}"
  } >"${statedir}/shim.conf"
  cp "${here}/docker-buildx-shim.sh" "${plugdir}/docker-buildx.tmp"
  chmod 0755 "${plugdir}/docker-buildx.tmp"
  mv "${plugdir}/docker-buildx.tmp" "${plugdir}/docker-buildx"

  # Proven, not assumed: the CLI must now resolve buildx to the shim, and the
  # shim must hand through to a buildx that answers.
  if ! docker buildx version >/dev/null 2>&1; then
    rm -f "${plugdir}/docker-buildx"
    [ "$real" != "${statedir}/docker-buildx" ] || mv "$real" "${plugdir}/docker-buildx"
    docker buildx rm "$builder" >/dev/null 2>&1 || true
    off "docker buildx stopped answering once the shim was installed, so it was taken out again."
  fi
fi

# --- 5. hand it to the job --------------------------------------------------
# Every later step uses the builder, including ones that never call `docker
# buildx use`. docker/setup-buildx-action exports the same variable, so the one
# that runs last decides -- what a customer composing the two would expect.
echo "BUILDX_BUILDER=${builder}" >>"${GITHUB_ENV:-/dev/null}"

ref="${host}/${name}:${key:-default}"
{
  echo "enabled=true"
  echo "builder=${builder}"
  echo "ref=${ref}"
  echo "cache-from=type=registry,ref=${ref}"
  echo "cache-to=type=registry,ref=${ref},mode=max,ignore-error=true"
} >>"$out"

if [ "$automatic" = "true" ]; then
  echo "runners.io layer cache: on, at ${host}/${name}. Every docker build in this job that names no cache of its own uses it."
else
  echo "runners.io layer cache: builder '${builder}' is ready and automatic is off; pass the cache-from and cache-to outputs to your build."
fi
