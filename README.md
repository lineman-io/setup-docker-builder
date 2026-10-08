# setup-docker-builder

The [runners.io](https://www.runners.io) Docker layer cache, in one line.

```yaml
- uses: lineman-io/setup-docker-builder@v1
```

Add it as a step before your build. Every later `docker build`,
`docker buildx build` and `docker/build-push-action` step in the same job then
reads its layers from the runners.io layer cache and writes new ones back. There
are no flags, hostnames or credentials to set.

```yaml
jobs:
  image:
    runs-on: ghwarp-4vcpu-ubuntu-2404
    steps:
      - uses: actions/checkout@v4
      - uses: lineman-io/setup-docker-builder@v1
      - run: docker build -t app .
```

**It only does anything on runners.io runners.** On GitHub-hosted runners, or
anywhere else, it changes nothing and says so in one notice, so a workflow that
runs in both places can keep the step without a condition. A cache that cannot
be reached never fails a build: the build runs without it.

Inputs (`key`, `automatic`) and outputs (`enabled`, `builder`, `ref`,
`cache-from`, `cache-to`) are described in [`action.yml`](action.yml) and in the
full documentation:
<https://www.runners.io/docs/caching/docker-layer-cache>.

## Versions

Pin `@v1`. It moves to the newest `v1.x.y` release; breaking changes would get
a new major version.

This repository is a published copy. The action is developed in the runners.io
monorepo and each release is copied here unchanged.

## Licence

[MIT](LICENSE)
