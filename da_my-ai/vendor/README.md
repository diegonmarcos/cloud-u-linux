# vendor/

Read-only upstream checkouts kept for reference and provenance. Nothing here is
built, packaged, or committed — every subdirectory is gitignored.

## goose-upstream

Upstream [block/goose](https://github.com/block/goose), pinned to:

    2694fff7e394ae7be7b63858f9b91b4658ac9200   (2026-07-30)

**Why it exists.** `da_my-konsole/agentic-ui/src/goose-sdk-zod.gen.ts` is a
hand-copy of `ui/sdk/src/generated/zod.gen.ts` from this commit. The published
`@aaif/goose-sdk` npm package (0.20.2) does not export `zRecipeDto` — upstream
builds it from workspace-local `ui/sdk` source — so the generated schema is
vendored directly instead of pulling the whole SDK build pipeline into the fork.
This checkout is the provenance for that file: it is what makes the copy
verifiable and re-derivable.

Verified identical at the pinned commit (80254 bytes, byte-for-byte).

**Note:** this pin is the provenance of the vendored schema. It is deliberately
*not* the version of goose we ship — that is pinned separately in `nix/goose.nix`
(currently the v1.44.0 release tarball, fetched by hash). The two move
independently; do not assume they match.

### Recreating it

Previously this lived loose at `~/git/_scratch/goose-upstream` as a full clone:
**642MB**, of which ~296MB was history and ~310MB was upstream's `documentation/`
marketing videos (`hero_light.mp4`, `goose-in-action.mp4`, …). A shallow,
blobless, sparse checkout of just the paths we reference is **27MB**:

```sh
git init goose-upstream && cd goose-upstream
git remote add origin https://github.com/block/goose
git sparse-checkout init --cone
git sparse-checkout set ui/sdk crates
git fetch --depth 1 --filter=blob:none origin 2694fff7e394ae7be7b63858f9b91b4658ac9200
git checkout FETCH_HEAD
```

### Re-syncing the vendored schema

To move to a newer upstream, fetch that SHA the same way, copy
`ui/sdk/src/generated/zod.gen.ts` over the vendored file, and update the pin
recorded above — so the provenance never drifts from the copy again.
