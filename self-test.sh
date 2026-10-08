#!/usr/bin/env bash
# Self-test for setup-docker-builder (RUN-109): both scripts, against a fake
# docker and a fake buildx, with no daemon and no network.
#
# WHAT A FAKE CAN AND CANNOT PROVE. It proves the decisions: which builds the
# shim rewrites and which it leaves alone, what reference it derives, that the
# action does nothing anywhere it should do nothing, and that a refusal leaves
# nothing behind. It cannot prove a registry served a layer -- that is what
# ghwarp-layer-cache-isolation-acceptance.yml does on the real fleet, and it
# runs this first so a broken decision fails in seconds rather than as a
# confusing cache miss.
#
# The fake buildx records its argv one argument per line, so an assertion sees
# exactly what the real one would be handed, spaces and all.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fails=0
checks=0
pass() { checks=$((checks + 1)); printf 'ok    %s\n' "$1"; }
fail() { checks=$((checks + 1)); fails=$((fails + 1)); printf 'FAIL  %s\n' "$1"; }
expect() { # expect <description> <command...>
  local d="$1"; shift
  if "$@"; then pass "$d"; else fail "$d"; fi
}

# --- the fakes --------------------------------------------------------------
mkdir -p "$work/bin" "$work/sys-plugins"

# The "real" buildx: records its argv, and keeps a tiny builder store so
# inspect/create/rm behave like the real ones.
cat >"$work/sys-plugins/docker-buildx" <<'FAKE'
#!/usr/bin/env bash
: >"$FAKE_ARGV"
for a in "$@"; do printf '%s\n' "$a" >>"$FAKE_ARGV"; done
# Record the builder this build actually ran on (RUN-617): a local-FROM build
# must arrive here with BUILDX_BUILDER=default, not the container builder.
[ -n "${FAKE_BUILDER:-}" ] && printf '%s' "${BUILDX_BUILDER:-}" >"$FAKE_BUILDER"
[ "${1:-}" = "buildx" ] && shift
case "${1:-}" in
  version) echo "github.com/docker/buildx v0.30.1 fake" ;;
  create)
    [ -z "${FAKE_CREATE_FAILS:-}" ] || exit 1
    shift; while [ $# -gt 0 ]; do [ "$1" = "--name" ] && touch "$FAKE_STORE/$2"; shift; done ;;
  inspect)
    n="${*: -1}"; [ "$n" = "--bootstrap" ] && n=""
    [ -z "$n" ] || [ "$n" = "inspect" ] || [ -e "$FAKE_STORE/$n" ] ;;
  rm) rm -f "$FAKE_STORE/${2:-}" ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$work/sys-plugins/docker-buildx"

# docker: `docker buildx ...` resolves the plugin the way the CLI does -- the
# user directory first -- and `docker info` reports whichever that resolves to.
cat >"$work/bin/docker" <<'FAKE'
#!/usr/bin/env bash
plug="${DOCKER_CONFIG}/cli-plugins/docker-buildx"
case "${1:-}" in
  buildx)
    if [ -x "$plug" ]; then exec "$plug" "$@"; fi
    exec "$FAKE_SYS_BUILDX" "$@" ;;
  info)
    # Two distinct `docker info` calls: store detection (DriverStatus) and
    # buildx-plugin discovery (ClientInfo.Plugins). FAKE_STORE_KIND empty = the
    # legacy store.
    case "$*" in
      *DriverStatus*) printf '%s' "${FAKE_STORE_KIND:-}" ;;
      *) if [ -x "$plug" ]; then echo "$plug"; else echo "$FAKE_SYS_BUILDX"; fi ;;
    esac ;;
  image)
    # `docker image inspect -f '{{len .RepoDigests}}' -- <ref>` (RUN-617). A
    # local-only image (FAKE_LOCAL) has zero repo digests; a pulled one
    # (FAKE_PULLED) has one; anything else is not present (non-zero exit).
    if [ "${2:-}" = inspect ]; then
      ref="${*: -1}"
      case " ${FAKE_LOCAL:-} " in *" $ref "*) echo 0; exit 0 ;; esac
      case " ${FAKE_PULLED:-} " in *" $ref "*) echo 1; exit 0 ;; esac
      exit 1
    fi
    exit 0 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$work/bin/docker"

# curl: answers whatever FAKE_HTTP says, and records whether the credential
# arrived on stdin rather than in argv.
cat >"$work/bin/curl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$FAKE_CURL_ARGV"
cat >"$FAKE_CURL_STDIN"
printf '%s' "${FAKE_HTTP:-200}"
FAKE
chmod +x "$work/bin/curl"

export PATH="$work/bin:$PATH"
export FAKE_SYS_BUILDX="$work/sys-plugins/docker-buildx"
export FAKE_CURL_ARGV="$work/curl.argv" FAKE_CURL_STDIN="$work/curl.stdin"

# A fresh job: its own docker config, outputs and env files.
fresh() {
  rm -rf "$work/job"
  mkdir -p "$work/job/dc" "$work/job/store"
  export DOCKER_CONFIG="$work/job/dc"
  export FAKE_STORE="$work/job/store" FAKE_ARGV="$work/job/argv"
  export GITHUB_OUTPUT="$work/job/out" GITHUB_ENV="$work/job/env"
  : >"$GITHUB_OUTPUT"; : >"$GITHUB_ENV"
  export GITHUB_REPOSITORY="Lineman-IO/Runners_IO"
  export GITHUB_ACTION_PATH="$here"
  export FAKE_BUILDER="$work/job/builder"
  : >"$FAKE_BUILDER"
  unset GHWARP_LAYER_CACHE INPUT_KEY INPUT_AUTOMATIC FAKE_HTTP FAKE_CREATE_FAILS BUILDX_BUILDER FAKE_LOCAL FAKE_PULLED FAKE_STORE_KIND
}
credential() { # credential <host>
  printf '{"auths":{"%s":{"auth":"%s"}}}' "$1" "$(printf 'x:secret-token' | base64 | tr -d '\n')" \
    >"$DOCKER_CONFIG/config.json"
}
setup() { bash "$here/setup.sh" >"$work/job/stdout" 2>"$work/job/stderr"; }
output() { sed -n "s/^$1=//p" "$GITHUB_OUTPUT" | tail -1; }
said() { grep -qF -- "$1" "$work/job/stdout"; }
nothing_installed() {
  [ ! -e "$DOCKER_CONFIG/cli-plugins/docker-buildx" ] && ! grep -q BUILDX_BUILDER "$GITHUB_ENV" &&
    [ -z "$(ls -A "$FAKE_STORE")" ]
}

echo "== setup.sh: the no-op cases"

fresh
setup
expect "exits 0 off the fleet" test $? -eq 0
expect "off the fleet: enabled=false" test "$(output enabled)" = "false"
expect "off the fleet: one notice saying so" said "::notice title=runners.io layer cache::This is not a runners.io runner"
expect "off the fleet: empty cache-from, which build-push-action reads as no cache" test -z "$(output cache-from)"
expect "off the fleet: nothing installed, no builder, no BUILDX_BUILDER" nothing_installed

fresh; export GHWARP_LAYER_CACHE="https://layers.runners.io"; credential "$GHWARP_LAYER_CACHE"; setup
expect "a host with a scheme is refused, not wired" test "$(output enabled)" = "false"
expect "...and nothing is installed" nothing_installed

fresh; export GHWARP_LAYER_CACHE="layers-gra1.runners.io:8443"; setup
expect "half a configuration (host, no credential) is a no-op" test "$(output enabled)" = "false"
expect "...that names the missing credential" said "holds no credential"
expect "...and installs nothing" nothing_installed

fresh; export GHWARP_LAYER_CACHE="layers-gra1.runners.io:8443"; credential "$GHWARP_LAYER_CACHE"
export FAKE_HTTP=401; setup
expect "a cache that refuses the credential is a no-op" test "$(output enabled)" = "false"
expect "...that says what it answered" said "answered '401'"
expect "...and installs nothing" nothing_installed

fresh; export GHWARP_LAYER_CACHE="layers-gra1.runners.io:8443"; credential "$GHWARP_LAYER_CACHE"
export FAKE_CREATE_FAILS=1; setup
expect "a builder that cannot be created is a no-op" test "$(output enabled)" = "false"
expect "...and installs nothing" nothing_installed

fresh; export GHWARP_LAYER_CACHE="layers-gra1.runners.io:8443"; credential "$GHWARP_LAYER_CACHE"
export INPUT_AUTOMATIC=yes; setup
expect "automatic must be true or false" test "$(output enabled)" = "false"

fresh; export GHWARP_LAYER_CACHE="layers-gra1.runners.io:8443"; credential "$GHWARP_LAYER_CACHE"
export INPUT_KEY="..."; setup
expect "a key with nothing valid in it is refused" test "$(output enabled)" = "false"
expect "...before anything is created" nothing_installed

echo "== setup.sh: on the fleet"

fresh; export GHWARP_LAYER_CACHE="layers-gra1.runners.io:8443"; credential "$GHWARP_LAYER_CACHE"
setup
rc=$?
expect "exits 0 on the fleet" test "$rc" -eq 0
expect "enabled=true" test "$(output enabled)" = "true"
expect "the builder is the job's builder from now on" grep -qx "BUILDX_BUILDER=runners-io" "$GITHUB_ENV"
expect "the shim is what docker now runs for buildx" grep -qF "the docker-buildx shim" "$DOCKER_CONFIG/cli-plugins/docker-buildx"
expect "the host is used VERBATIM -- the guest service port survives (WARP-271)" \
  test "$(output ref)" = "layers-gra1.runners.io:8443/runners-io:default"
expect "the repository name is made a valid registry name" grep -qx "CACHE_NAME=runners-io" "$DOCKER_CONFIG/cli-plugins/.runners-io/shim.conf"
expect "cache-to never fails a build" test "$(output cache-to)" = "type=registry,ref=layers-gra1.runners.io:8443/runners-io:default,mode=max,ignore-error=true"
expect "the credential went to curl on stdin" grep -q "Authorization: Basic" "$FAKE_CURL_STDIN"
expect "...and never in its argv" sh -c "! grep -q 'secret\|Basic' '$FAKE_CURL_ARGV'"
expect "...and is printed nowhere" sh -c "! grep -q \"$(printf 'x:secret-token' | base64)\" '$work/job/stdout' '$work/job/stderr'"
expect "the shim hands to the system buildx" grep -qx "REAL_BUILDX=$FAKE_SYS_BUILDX" "$DOCKER_CONFIG/cli-plugins/.runners-io/shim.conf"

setup
expect "running it twice in one job keeps the real buildx, not the shim" \
  grep -qx "REAL_BUILDX=$FAKE_SYS_BUILDX" "$DOCKER_CONFIG/cli-plugins/.runners-io/shim.conf"

echo "== setup.sh: the builder follows the image store (RUN-617)"

# The legacy store: a container-driver builder is created and exported.
fresh; export GHWARP_LAYER_CACHE="layers-gra1.runners.io:8443"; credential "$GHWARP_LAYER_CACHE"
setup
expect "legacy store -> the container builder" grep -qx "BUILDX_BUILDER=runners-io" "$GITHUB_ENV"
expect "legacy store -> shim.conf names it" grep -qx "BUILDER=runners-io" "$DOCKER_CONFIG/cli-plugins/.runners-io/shim.conf"
expect "legacy store -> the container builder was created" test -e "$FAKE_STORE/runners-io"

# The containerd store: the DEFAULT builder, which sees local images and still
# exports the cache, so no container builder is created.
fresh; export GHWARP_LAYER_CACHE="layers-gra1.runners.io:8443"; credential "$GHWARP_LAYER_CACHE"
export FAKE_STORE_KIND="io.containerd.snapshotter.v1"; setup
expect "containerd store -> enabled" test "$(output enabled)" = "true"
expect "containerd store -> the default builder" test "$(output builder)" = "default"
expect "containerd store -> shim.conf says default" grep -qx "BUILDER=default" "$DOCKER_CONFIG/cli-plugins/.runners-io/shim.conf"
expect "containerd store -> NO container builder created" test ! -e "$FAKE_STORE/runners-io"
expect "containerd store -> the cache is still wired" test "$(output cache-to)" = "type=registry,ref=layers-gra1.runners.io:8443/runners-io:default,mode=max,ignore-error=true"

fresh; export GHWARP_LAYER_CACHE="layers-gra1.runners.io:8443"; credential "$GHWARP_LAYER_CACHE"
mkdir -p "$DOCKER_CONFIG/cli-plugins"; cp "$FAKE_SYS_BUILDX" "$DOCKER_CONFIG/cli-plugins/docker-buildx"
setup
expect "a buildx already in the user directory is moved aside and handed to" \
  grep -qx "REAL_BUILDX=$DOCKER_CONFIG/cli-plugins/.runners-io/docker-buildx" "$DOCKER_CONFIG/cli-plugins/.runners-io/shim.conf"

fresh; export GHWARP_LAYER_CACHE="layers-gra1.runners.io:8443"; credential "$GHWARP_LAYER_CACHE"
export INPUT_AUTOMATIC=false; setup
expect "automatic=false: the builder, but no shim" test ! -e "$DOCKER_CONFIG/cli-plugins/docker-buildx"
expect "automatic=false: still enabled, with outputs to wire by hand" test "$(output enabled)" = "true"

fresh; export GHWARP_LAYER_CACHE="layers.runners.io"; credential "$GHWARP_LAYER_CACHE"; setup
expect "a portless host (a burst VM's :443 door) is also used verbatim" test "$(output ref)" = "layers.runners.io/runners-io:default"

fresh; export GHWARP_LAYER_CACHE="layers-gra1.runners.io:8443"; credential "$GHWARP_LAYER_CACHE"
export INPUT_KEY="feature/My Branch"; setup
expect "a key is made a valid tag" test "$(output ref)" = "layers-gra1.runners.io:8443/runners-io:feature-My-Branch"

echo "== docker-buildx-shim.sh: which builds it touches"

fresh
conf="$work/shim.conf"
export RUNNERS_IO_SHIM_CONFIG="$conf"
writeconf() { # writeconf [key]
  printf 'REAL_BUILDX=%s\nCACHE_HOST=layers-gra1.runners.io:8443\nCACHE_NAME=runners-io\nBUILDER=runners-io\nKEY=%s\n' \
    "$FAKE_SYS_BUILDX" "${1:-}" >"$conf"
}
writeconf
shim() { bash "$here/docker-buildx-shim.sh" "$@" >/dev/null 2>"$work/shim.err"; }
argv() { cat "$FAKE_ARGV"; }
added() { grep -qx -- "--cache-from" "$FAKE_ARGV"; }
untouched() { ! grep -q -- "runners-io:build-\|layers-gra1" "$FAKE_ARGV"; }
keyof() { sed -n 's/^type=registry,ref=layers-gra1.runners.io:8443\/runners-io:\([^,]*\)$/\1/p' "$FAKE_ARGV"; }

shim buildx build -t app .
expect "a build naming no cache gets one" added
expect "...through the guest service port, as configured" grep -q "^type=registry,ref=layers-gra1.runners.io:8443/runners-io:build-" "$FAKE_ARGV"
expect "...with mode=max and ignore-error on the export" grep -q ",mode=max,ignore-error=true$" "$FAKE_ARGV"
expect "...inserted right after the subcommand, the rest intact" \
  test "$(argv | tr '\n' ' ')" = "buildx build --cache-from type=registry,ref=layers-gra1.runners.io:8443/runners-io:$(keyof) --cache-to type=registry,ref=layers-gra1.runners.io:8443/runners-io:$(keyof),mode=max,ignore-error=true -t app . "
expect "...and the log says which reference" grep -q "runners.io layer cache: layers-gra1.runners.io:8443/runners-io:build-" "$work/shim.err"
base_key="$(keyof)"

shim buildx b -t app .
expect "the short form 'b' is a build too" added

shim buildx build --build-arg "MSG=two words" .
expect "an argument with a space survives" grep -qx "MSG=two words" "$FAKE_ARGV"

for case in "--cache-from type=gha" "--cache-from=type=gha" "--cache-to type=gha" "--cache-to=type=gha,mode=max"; do
  # shellcheck disable=SC2086 # split on purpose: one flag, one value
  shim buildx build $case .
  expect "a build that names its own cache is left alone ($case)" untouched
done

shim buildx --builder other build .
expect "a build sent to another builder (global --builder) is left alone" untouched
shim buildx build --builder=other .
expect "a build sent to another builder (--builder=) is left alone" untouched
shim buildx build --builder other .
expect "a build sent to another builder (--builder x) is left alone" untouched
BUILDX_BUILDER=other shim buildx build .
expect "a build on BUILDX_BUILDER=other is left alone" untouched
shim buildx build --builder runners-io .
expect "a build naming OUR builder still gets the cache" added

for sub in "bake" "ls" "version" "inspect runners-io" "imagetools inspect x"; do
  # shellcheck disable=SC2086
  shim buildx $sub
  expect "'buildx $sub' passes straight through" test "$(argv | tr '\n' ' ')" = "buildx $sub "
done
shim docker-cli-plugin-metadata
expect "the CLI plugin handshake passes straight through" test "$(argv)" = "docker-cli-plugin-metadata"
for flag in "--call check" "--call=outline" "--check" "--print" "--help" "-h"; do
  # shellcheck disable=SC2086
  shim buildx build $flag .
  expect "'build $flag' evaluates, does not export, and is left alone" untouched
done

echo "== docker-buildx-shim.sh: one cache per image"

shim buildx build ./
expect "'./' is the same image as '.'" test "$(keyof)" = "$base_key"
shim buildx build -f a/Dockerfile a
k_a="$(keyof)"
shim buildx build -f b/Dockerfile b
expect "two Dockerfiles are two caches" test "$(keyof)" != "$k_a"
shim buildx build --file=a/Dockerfile ./a/
expect "the same image spelled differently is one cache" test "$(keyof)" = "$k_a"
shim buildx build -fa/Dockerfile a
expect "-fPATH is read as the file" test "$(keyof)" = "$k_a"
shim buildx build --target test -f a/Dockerfile a
expect "a different target is a different cache" test "$(keyof)" != "$k_a"
shim buildx build svc-one
k_one="$(keyof)"
shim buildx build svc-two
expect "two local contexts with the default Dockerfile are two caches" test "$(keyof)" != "$k_one"
shim buildx build --iidfile /tmp/x1 https://github.com/o/r.git#1111111
k_git="$(keyof)"
shim buildx build --iidfile /tmp/x2 https://github.com/o/r.git#2222222
expect "a remote context's commit is NOT in the key (build-push-action's default)" test "$(keyof)" = "$k_git"

writeconf "my-image"
shim buildx build -f a/Dockerfile a
expect "a key from the action is used as given" test "$(keyof)" = "my-image"

echo "== docker-buildx-shim.sh: failure"
printf 'REAL_BUILDX=%s\n' "$work/nowhere" >"$conf"
shim buildx build .
rc=$?
expect "with no real buildx it fails loudly (127), not silently" test "$rc" -eq 127
expect "...saying how to recover" grep -q "remove .* to restore buildx" "$work/shim.err"

echo "== docker-buildx-shim.sh: a FROM built earlier in the job (RUN-617)"

dfdir="$work/df"
mkdir -p "$dfdir"
writedf() { printf '%s\n' "$2" >"$dfdir/$1"; } # writedf <name> <contents>
builderof() { cat "$FAKE_BUILDER" 2>/dev/null; }
# run <dockerfile-name> [extra shim args...]
runbuild() { local df="$1"; shift; : >"$FAKE_BUILDER"; shim buildx build -f "$dfdir/$df" "$@" "$dfdir"; }

writeconf # no fixed key

writedf local $'FROM rvf-local-base:1\nRUN echo hi'
FAKE_LOCAL="rvf-local-base:1" runbuild local
expect "a FROM a same-job local image runs on the default builder" test "$(builderof)" = "default"
expect "...and gets NO registry cache (the container builder cannot see it)" untouched
expect "...and says why" grep -q "the cache builder cannot see" "$work/shim.err"

writedf pulled $'FROM alpine:3.20\nRUN echo hi'
FAKE_PULLED="alpine:3.20" runbuild pulled
expect "a FROM a pulled public image keeps the cache" added
expect "...on the cache builder, not forced to default" test -z "$(builderof)"

writedf multi $'FROM rvf-local-base:1 AS build\nRUN echo hi\nFROM build\nRUN echo bye'
FAKE_LOCAL="rvf-local-base:1" runbuild multi
expect "a multi-stage build FROM a local base is routed to default" test "$(builderof)" = "default"

writedf stages $'FROM alpine:3.20 AS a\nRUN echo hi\nFROM a AS b\nRUN echo bye'
FAKE_PULLED="alpine:3.20" runbuild stages
expect "a later FROM <stage> is not mistaken for a local image" added
expect "...and the pulled base keeps the cache builder" test -z "$(builderof)"

writedf argdefault $'ARG BASE=rvf-local-base:1\nFROM $BASE\nRUN echo hi'
FAKE_LOCAL="rvf-local-base:1" runbuild argdefault
expect "an ARG-default FROM that resolves to a local base is routed to default" test "$(builderof)" = "default"

writedf argbuild $'ARG BASE=alpine:3.20\nFROM ${BASE}\nRUN echo hi'
FAKE_LOCAL="my-local:9" FAKE_PULLED="alpine:3.20" runbuild argbuild --build-arg BASE=my-local:9
expect "a --build-arg overriding the ARG to a local base wins, and routes to default" test "$(builderof)" = "default"

writedf unresolved $'FROM $MYSTERY_BASE\nRUN echo hi'
runbuild unresolved
expect "an unresolved-ARG FROM is skipped, not guessed: the cache is kept" added

# On the DEFAULT builder (containerd store) a local FROM is NOT rerouted: that
# builder is the daemon's own store, so it sees the local image AND caches it.
printf 'REAL_BUILDX=%s\nCACHE_HOST=layers-gra1.runners.io:8443\nCACHE_NAME=runners-io\nBUILDER=default\nKEY=\n' \
  "$FAKE_SYS_BUILDX" >"$conf"
writedf localdef $'FROM rvf-local-base:1\nRUN echo hi'
FAKE_LOCAL="rvf-local-base:1" runbuild localdef
expect "on the default builder a local FROM keeps the cache (the daemon sees it)" added
expect "...and is not forced anywhere" test -z "$(builderof)"
writeconf # restore BUILDER=runners-io for any later case

echo
if [ "$checks" -lt 80 ]; then
  echo "FAIL: only ${checks} checks ran; the self-test has stopped exercising what it claims to"
  exit 1
fi
echo "${checks} checks, ${fails} failed"
[ "$fails" -eq 0 ]
