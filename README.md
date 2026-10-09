# setup-docker-builder has moved

**Use [`runners-io/setup-docker-builder`](https://github.com/runners-io/setup-docker-builder):**

```yaml
- uses: runners-io/setup-docker-builder@v1
```

This repository only forwards to it now. A workflow that still says
`uses: lineman-io/setup-docker-builder@v1` keeps working: this `v1` calls
`runners-io/setup-docker-builder` at its v1.0.1 release, passing the `automatic`
and `key` inputs through and the `enabled`, `builder`, `ref`, `cache-from` and
`cache-to` outputs back. `v1.0.0` here is the original action, unchanged.

Documentation: <https://www.runners.io/docs/caching/docker-layer-cache>.
