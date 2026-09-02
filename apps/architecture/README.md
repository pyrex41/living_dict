# Architecture site

An evidence-first explainer for how Living Dictionary actually runs. It is a
standalone Vite artifact so it can be deployed independently or linked from the
main project site.

```bash
npm install
npm run dev
npm run build
```

The component-status table deliberately distinguishes the direct `ld.run` hot
path from conditional OODA/dictionary behavior, benchmark orchestration, and
alternate runtime bodies. Keep those labels aligned with `beam/README.md` and
`docs/ARCHITECTURE.md` when the architecture changes.
