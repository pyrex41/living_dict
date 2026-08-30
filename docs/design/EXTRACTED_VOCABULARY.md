# Extracted vocabulary: skills from receipts, not from the planner

**Date:** 2026-08-29
**Status:** Draft (implementation spike)
**Live body:** BEAM + `shen/critic`. No Python overlay path. No nested cartridge.

Extends [`HARNESS_CARTRIDGE.md`](HARNESS_CARTRIDGE.md) substrate (primitive spec, identity `hash(D)`, grant+path retrieval) and **rejects** planner-authored overlays as the generated object.

## Thesis

JIT-Agent generates a harness *before* the rollout. living_dict should mint a skill *after* evidence.

Exp 0 (`beam/runs/exp0-kill-switch/receipt.json`): 105/105 warm, 15/15 seq-8 both arms, **one** `dictionary.promoted` (`INSTALL`, copied from the system prompt), **zero** quarantines. Programs were artifact dumps + `RUN-GATES RECEIPT`. The planner will not name skills when one envelope already discharges the claim.

So: the host compiles a colon word from a successful episode. Shen admits it. The next episode may call it. The model does not have to emit `:`.

## Non-goals

- Nested `envelope.cartridge`, generated `(M,P,A,F)`, `COMPLETE`, planner-authored type rules.
- Shen join-shape / fuel theorems (PR 5 of the cartridge plan).
- Pareto / narrow (PR 7) until there are many admitted words.
- Editing `eval/`. New host Forth words. Python CLI as overlay host.

## Extract (deterministic, no LLM)

After `gates.measured` with `ok=true`, if this episode introduced **no** planner colon words (or in addition to them — v1 is **fallback only** when `Forth.defined_names(vm) -- prelude` is empty):

1. Collect **product writes**: `WRITE-FILE` literal paths from the executed program / host mutations, minus `claims.json`, `.sb/*`, `.livingdict-run/*`, `.git/*`.
2. If none, do not extract.
3. Detect the install idiom: pairs `S" key" USE-ARTIFACT S" path" WRITE-FILE` with `key == path`, then `RUN-GATES`/`RECEIPT` ignored for the body.
4. Synthesize one word:
   - **Name:** `INSTALL-` + `SAFE_NAME` slug of the sorted unique path-region (e.g. `app/config.py` → `INSTALL-APP-CONFIG`). Never shadow reserved host words.
   - **Contract:** `( key -- receipt | read, write )` matching the generic installer body, **or** `( -- receipt | read, write )` with paths literal in the body if a single frozen path is the whole skill. v1: generic installer body, same as the prompt example:
     `: NAME ( key -- | read, write ) DUP USE-ARTIFACT SWAP WRITE-FILE DROP ;`
   - **path_region:** those product write paths (not the episode's full `allowed_globs`, not `claims.json`).
   - **effects:** from the contract.
   - **task_families:** `[]` on live jobs.
5. **Dedup:** if `words/NAME.fs` already has identical source, skip (byte-identical persist). Distinct path_regions ⇒ distinct names, never union regions onto one `INSTALL` (that would break grant+path drop).
6. **Admit:** `LdHost.Critic.validate` on `prelude ⊕ ": NAME contract body ;"` with the episode grant. Reject ⇒ `dictionary.promotion_evidence` (not a `.fs` file). Accept ⇒ existing `save_words` + identity intern + `dictionary.promoted`.
7. Do not put `RUN-GATES` in the extracted body. Host still measures after the episode.

Planner-authored contracted colon words keep the current `promote/5` path and win over extract in the same episode.

## Observation

`HARNESS DICTIONARY` already lists prelude names + source. Extracted words must appear there the same way. No new host word. No cartridge field on the envelope.

## Exp A (offline, no planner)

Replay `beam/runs/exp0-kill-switch` traces (and fixtures if that tree is absent): for each successful warm episode, extract without executing the VM. Build a synthetic dictionary. Then:

- Admit rate (Shen accept / candidates).
- Distinct names / path_regions (expect more than one family-scoped installer, not a single `INSTALL`).
- Grant+path: `config-08` globs retrieve the config installer; `parser-08` does not.
- Do **not** require a live seq-8 LLM re-run for this spike.

Runner: `mix ld.extract` or `mix test` fixtures under `beam/test/extract_test.exs`. Writes under `beam/runs/`, never `eval/`.

## Flags

Default on for extract-after-success (`LD_EXTRACT=1` default **1** — this is the dictionary's reason to exist; disable with `0` for A/B). Retrieval still defaults `LD_DICT_MODE=load-all`.

## Tests (`mix test` in `beam/`)

- Idiom with `app/config.py` + `claims.json` → one word, path_region is only `app/config.py`.
- Same source second time → no new file.
- Two regions → two names; retrieve config grant hits only the config word.
- Critic reject (e.g. reserved name) → evidence event, no `.fs`.
- Planner-defined contracted word still promotes; extract does not overwrite it in that episode.
- `eval/` untouched.
