#!/usr/bin/env bash
# runners.io setup-docker-builder: the docker-buildx shim (RUN-109).
#
# WHAT THIS IS. setup.sh installs this file as ~/.docker/cli-plugins/docker-buildx,
# which the Docker CLI searches BEFORE the system plugin directories. So every
# `docker buildx build`, every `docker build` (an alias for it since Docker 23),
# and docker/build-push-action (which runs `docker buildx build`) comes through
# here, and everything is handed to the real buildx unchanged -- except a build
# that names no cache of its own, which is given the job's layer cache.
#
# WHY A SHIM AND NOT AN OUTPUT. The ticket's bar is "a workflow using the action
# alone gets a cache hit", and buildx reads no environment variable that sets a
# default cache. Without this, adoption is the action PLUS two flags on every
# build step -- the hand-written wiring RUN-109 exists to remove, two halves of
# which fail silently when wrong.
#
# WHAT IT NEVER DOES, each a rule with a reason:
#   * Touch a build that names a cache. --cache-from or --cache-to anywhere and
#     the customer is managing their cache; adding a second one would split it.
#   * Touch a build on another builder. Whether a builder the customer chose can
#     export a registry cache is not ours to know -- on a legacy image store the
#     docker driver refuses cache-to as a hard error, not a warning -- so a
#     build sent elsewhere is left exactly as written. The builder setup.sh
#     picked (the default one on a containerd store, runners-io otherwise) is
#     the only one this adds a cache to.
#   * Fail a build. cache-to carries ignore-error=true: an unreachable cache is
#     a slower build, never a red one.
#   * Touch anything that is not a build: bake, ls, inspect, version, and the
#     plugin-metadata handshake all pass straight through.
#
# THE CONFIG is a key=value file beside this one, read line by line and never
# sourced: it is data, and a file executed as code is a second way in.

set -uo pipefail

shim_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
config="${RUNNERS_IO_SHIM_CONFIG:-${shim_dir}/.runners-io/shim.conf}"

real="" host="" name="" builder="" key=""
if [ -r "$config" ]; then
  while IFS='=' read -r k v; do
    case "$k" in
      REAL_BUILDX) real="$v" ;;
      CACHE_HOST) host="$v" ;;
      CACHE_NAME) name="$v" ;;
      BUILDER) builder="$v" ;;
      KEY) key="$v" ;;
    esac
  done <"$config"
fi

if [ -z "$real" ] || [ ! -x "$real" ]; then
  # Nothing to hand to. This cannot be made right from here, and staying quiet
  # would turn into "docker: 'buildx' is not a docker command" with no clue why.
  echo "runners.io setup-docker-builder: the real docker-buildx is missing (config: ${config})." >&2
  echo "runners.io setup-docker-builder: remove ${BASH_SOURCE[0]} to restore buildx." >&2
  exit 127
fi

# The Docker CLI runs a plugin as `<plugin> <plugin-name> <args...>`, so a build
# arrives as `buildx build ...`. The metadata handshake arrives with no name.
args=("$@")
i=0
[ "${args[0]:-}" = "buildx" ] && i=1

# Global buildx flags may come before the subcommand. --builder is the one that
# matters: it decides whether this build runs on the builder setup.sh made.
chosen="${BUILDX_BUILDER:-}"
while [ "$i" -lt "${#args[@]}" ]; do
  case "${args[$i]}" in
    --builder) chosen="${args[$((i + 1))]:-}"; i=$((i + 2)) ;;
    --builder=*) chosen="${args[$i]#--builder=}"; i=$((i + 1)) ;;
    -D | --debug) i=$((i + 1)) ;;
    *) break ;;
  esac
done
sub="${args[$i]:-}"

passthrough() { exec "$real" "${args[@]}"; }

# RUN-617: a build whose FROM is an image built earlier in THIS job cannot run
# on the container-driver builder. That builder is its own BuildKit in a
# container and cannot see the daemon's local image store, so a `FROM
# my-local-base:1` fails with "pull access denied" -- the build worked on the
# default docker driver and breaks the moment this action switches it. So before
# wiring the cache, look for a FROM that names an image the daemon holds with NO
# registry digest (i.e. one that was built here, never pulled or pushed), and if
# there is one, run that build on the default docker driver with no cache, so it
# succeeds exactly as it did before. An image WITH a registry digest is left on
# the cache builder -- the container builder can pull it.
#
# Best effort by design: it resolves ${ARG}/$ARG in a FROM from --build-arg and
# from `ARG NAME=default`, and skips a FROM it cannot resolve rather than
# guessing. A base it cannot see through (an unresolved ARG, a stdin or remote
# Dockerfile) keeps the cache and behaves as before -- no worse than today.
local_base=""

# arg_value NAME -> the build-time value of NAME: a --build-arg NAME=val, then a
# bare --build-arg NAME from the environment, then an ARG NAME=default.
arg_value() {
  local want="$1" kv
  for kv in "${bargs[@]:-}"; do
    case "$kv" in
      "$want"=*) printf '%s' "${kv#*=}"; return 0 ;;
      "$want") printf '%s' "${!want:-}"; return 0 ;;
    esac
  done
  for kv in "${argdefs[@]:-}"; do
    case "$kv" in "$want"=*) printf '%s' "${kv#*=}"; return 0 ;; esac
  done
  return 1
}

# resolve_arg_refs replaces ${NAME} and $NAME in its argument. An unresolved one
# is left as-is, which makes expand_from skip the FROM rather than inspect a
# literal "$BASE".
resolve_arg_refs() {
  local s="$1" out="" i=0 c name
  while [ "$i" -lt "${#s}" ]; do
    c="${s:$i:1}"
    if [ "$c" != '$' ]; then out="${out}${c}"; i=$((i + 1)); continue; fi
    i=$((i + 1))
    if [ "${s:$i:1}" = '{' ]; then
      i=$((i + 1)); name=""
      while [ "$i" -lt "${#s}" ] && [ "${s:$i:1}" != '}' ]; do name="${name}${s:$i:1}"; i=$((i + 1)); done
      [ "${s:$i:1}" = '}' ] && i=$((i + 1))
    else
      name=""
      while [ "$i" -lt "${#s}" ] && case "${s:$i:1}" in [A-Za-z0-9_]) true ;; *) false ;; esac; do
        name="${name}${s:$i:1}"; i=$((i + 1))
      done
    fi
    out="${out}$(arg_value "$name")"
  done
  printf '%s' "$out"
}

# is_local_only_image reports whether the daemon holds ref with no registry
# digest -- a base built in this job, which the container builder cannot reach.
is_local_only_image() {
  local ref="$1" n
  n="$(docker image inspect -f '{{len .RepoDigests}}' -- "$ref" 2>/dev/null)" || return 1
  [ "$n" = "0" ]
}

# scan_for_local_base reads the Dockerfile and sets local_base to the first FROM
# that names a local-only image, returning 0 if it finds one.
scan_for_local_base() {
  local dockerfile="$1" ctx="$2" path line tok img low
  case "$ctx" in *://* | git@* | "") return 1 ;; esac # remote/empty context: nothing local to read
  path="$dockerfile"
  [ -n "$path" ] || path="${ctx}/Dockerfile"
  case "$path" in -) return 1 ;; esac # Dockerfile on stdin: cannot scan, keep cache
  [ -r "$path" ] || return 1

  argdefs=()
  stages=" "
  while IFS= read -r line || [ -n "$line" ]; do
    # Strip a trailing comment and surrounding whitespace, case-insensitively
    # match the instruction keyword.
    line="${line%%$'\r'}"
    case "$line" in
      [Aa][Rr][Gg][[:space:]]*)
        tok="$(printf '%s' "$line" | awk '{print $2}')"
        case "$tok" in *=*) argdefs+=("$tok") ;; esac
        ;;
      [Ff][Rr][Oo][Mm][[:space:]]*)
        # Drop the keyword and any --platform/--flag, take the image word.
        img=""
        for tok in $line; do
          case "$tok" in
            [Ff][Rr][Oo][Mm]) continue ;;
            --*) continue ;;
            *) img="$tok"; break ;;
          esac
        done
        img="$(resolve_arg_refs "$img")"
        low="$(printf '%s' "$img" | tr '[:upper:]' '[:lower:]')"
        # A stage alias, scratch, or a still-unresolved ARG is not an image.
        if [ "$low" = scratch ] || [ -z "$img" ]; then :
        elif case "$img" in *'$'*) true ;; *) false ;; esac; then :        # unresolved ARG
        elif case "$stages" in *" $low "*) true ;; *) false ;; esac; then : # a prior stage
        elif is_local_only_image "$img"; then local_base="$img"; return 0
        fi
        # Record this build's own stage alias so a later FROM <alias> is not
        # mistaken for an image.
        tok="$(printf '%s' "$line" | awk '{for(i=1;i<=NF;i++) if(tolower($i)=="as"){print tolower($(i+1)); exit}}')"
        [ -n "$tok" ] && stages="${stages}${tok} "
        ;;
    esac
  done < "$path"
  return 1
}

elsewhere() {
  echo "runners.io layer cache: not added -- this build runs on builder '$1', not '${builder}'" >&2
  passthrough
}

[ "$sub" = "build" ] || [ "$sub" = "b" ] || passthrough
if [ -z "$host" ] || [ -z "$name" ]; then passthrough; fi
if [ -n "$chosen" ] && [ "$chosen" != "$builder" ]; then elsewhere "$chosen"; fi

# Read the build's own flags. Only three matter: whether it names a cache (then
# hands off), which Dockerfile and target it builds (which image it IS), and
# whether it is a build at all (--call/--check/--print evaluate, never export).
file="" target="" context=""
bargs=()
j=$((i + 1))
while [ "$j" -lt "${#args[@]}" ]; do
  a="${args[$j]}"
  case "$a" in
    --cache-from | --cache-from=* | --cache-to | --cache-to=*)
      echo "runners.io layer cache: not added -- this build names its own cache" >&2
      passthrough
      ;;
    --call | --call=* | --check | --print | -h | --help) passthrough ;;
    --build-arg) bargs+=("${args[$((j + 1))]:-}"); j=$((j + 1)) ;;
    --build-arg=*) bargs+=("${a#--build-arg=}") ;;
    --builder) [ "${args[$((j + 1))]:-}" = "$builder" ] || elsewhere "${args[$((j + 1))]:-}"; j=$((j + 1)) ;;
    --builder=*) [ "${a#--builder=}" = "$builder" ] || elsewhere "${a#--builder=}" ;;
    -f | --file) file="${args[$((j + 1))]:-}"; j=$((j + 1)) ;;
    --file=*) file="${a#--file=}" ;;
    -f=*) file="${a#-f=}" ;;
    -f?*) file="${a#-f}" ;;
    --target) target="${args[$((j + 1))]:-}"; j=$((j + 1)) ;;
    --target=*) target="${a#--target=}" ;;
  esac
  j=$((j + 1))
done
last="${args[$((${#args[@]} - 1))]}"
case "$last" in
  -* | *://* | git@*) ;; # a flag, or a remote context whose URL carries the commit
  *) context="${last#./}"; context="${context%/}"; [ -n "$context" ] || context="." ;;
esac

# RUN-617: hand a build that is FROM a same-job local image to the default
# docker driver -- the container builder cannot see it -- with no cache, so it
# builds as it did before this action. BUILDX_BUILDER=default overrides the
# builder setup.sh exported, for this one build only.
#
# Only when the configured builder is NOT the default one. On a containerd-store
# daemon setup.sh picks the default builder, which IS the daemon's store and
# sees every local image, so there is nothing to reroute and the cache applies
# to a local-FROM build like any other.
if [ "$builder" != "default" ] && scan_for_local_base "$file" "$context"; then
  echo "runners.io layer cache: not added -- this build is FROM \"${local_base}\", an image" >&2
  echo "runners.io layer cache: built earlier in this job that the cache builder cannot see;" >&2
  echo "runners.io layer cache: building on the default docker builder instead." >&2
  exec env BUILDX_BUILDER=default "$real" "${args[@]}"
fi

# WHICH IMAGE IS THIS. One cache per image, or two images built in one job
# overwrite each other's cache manifest and both miss -- silently, the failure
# this ticket was filed about. A remote context is left out deliberately:
# docker/build-push-action's default context is the repository URL WITH THE
# COMMIT in it, so including it would give every commit a new, empty cache.
if [ -z "$key" ]; then
  if command -v sha256sum >/dev/null 2>&1; then
    sum="$(printf 'file=%s\ntarget=%s\ncontext=%s\n' "$file" "$target" "$context" | sha256sum)"
  else
    sum="$(printf 'file=%s\ntarget=%s\ncontext=%s\n' "$file" "$target" "$context" | shasum -a 256)"
  fi
  key="build-${sum:0:12}"
fi

ref="${host}/${name}:${key}"
echo "runners.io layer cache: ${ref}" >&2
exec "$real" "${args[@]:0:$((i + 1))}" \
  --cache-from "type=registry,ref=${ref}" \
  --cache-to "type=registry,ref=${ref},mode=max,ignore-error=true" \
  "${args[@]:$((i + 1))}"
