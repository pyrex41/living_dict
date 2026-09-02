# Architecture site

An evidence-first explainer for how Living Dictionary actually runs. It is a
native Hugo site: content and component evidence are data-driven, the page is
rendered at build time, and the browser receives only static HTML/CSS/JS.

```bash
hugo server --disableFastRender
hugo --minify
```

The component-status table deliberately distinguishes the direct `ld.run` hot
path from conditional OODA/dictionary behavior, benchmark orchestration, and
alternate runtime bodies. Keep those labels aligned with `beam/README.md` and
`docs/ARCHITECTURE.md` when the architecture changes.

Hugo fingerprints and minifies the CSS and interaction script. There is no
Node dependency or client framework.
