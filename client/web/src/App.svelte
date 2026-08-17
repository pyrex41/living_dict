<script>
  import { onMount, tick } from "svelte";

  let health = { ok: false, critic: "?", shen: false, workspace: "", dictionary: "", product_url: "" };
  let messages = [];
  let draft = "";
  let rawForth = false;
  let once = false;
  let busy = false;
  let stopping = false;
  let thread;
  let productTick = 0;
  let lastWork = { gates: [], previews: [], product_url: "" };

  const MAX_TURNS = 32;

  onMount(() => {
    ping();
    const id = setInterval(ping, 15000);
    return () => clearInterval(id);
  });

  async function ping() {
    try {
      const r = await fetch("/health");
      health = await r.json();
      health.ok = true;
    } catch {
      health = { ok: false, critic: "?", shen: false, workspace: "", dictionary: "", product_url: "" };
    }
  }

  function ensureReceipt(program) {
    const words = program.toUpperCase().split(/\s+/);
    return words.includes("RECEIPT") ? program.trim() : program.trim() + " RECEIPT";
  }

  function claimsDischarged(check) {
    if (!check || !Array.isArray(check.gates) || check.gates.length === 0) return false;
    const claims = check.gates.filter((g) => g.name === "claims");
    if (!claims.length) return false;
    if (claims.some((g) => !g.passed)) return false;
    if (check.gates.some((g) => g.name === "look" && !g.skipped && !g.passed)) return false;
    return true;
  }

  function extraFrom(body) {
    const errors = (body && (body.errors || body.details)) || [];
    if (errors.length) return errors.map((item) => "critic: " + item).join("\n");
    return "";
  }

  function machineFrom(body, status, episode, fallbackProgram) {
    const rejected = Boolean(body && body.critic === "reject");
    const ok = Boolean(body && body.ok) && status < 400 && !rejected;
    const artifacts = (body && body.plan && body.plan.artifacts) || {};
    return {
      role: "machine",
      ok,
      status,
      episode,
      critic: body && body.critic,
      rationale: body && body.plan && body.plan.rationale,
      program: (body && body.plan && body.plan.program) || fallbackProgram,
      artifacts,
      artifactKeys: Object.keys(artifacts),
      model: body && body.plan && body.plan.model,
      continuing: false,
      gates: (body && body.receipt && body.receipt.check && body.receipt.check.gates) || [],
      error: body && body.error,
      details: (body && (body.errors || body.details)) || [],
      changed: (body && body.receipt && body.receipt.changed_files) || [],
      stack: body && body.result && body.result.stack_depth,
      defined: (body && body.result && body.result.defined) || [],
      workspace: body && body.workspace,
      previews: (body && body.previews) || [],
      product_url: body && body.product_url,
    };
  }

  function rememberWork(body) {
    if (!body) return;
    const byPath = {};
    for (const p of lastWork.previews || []) {
      if (p && p.path) byPath[p.path] = p;
    }
    for (const p of body.previews || []) {
      if (p && p.path) byPath[p.path] = p;
    }
    const planned = body.plan && body.plan.artifacts;
    if (planned) {
      for (const path of Object.keys(planned)) {
        let text = String(planned[path] ?? "");
        if (text.length > 2500) text = text.slice(0, 2500) + "\n…";
        byPath[path] = { path, text };
      }
    }
    lastWork.previews = Object.keys(byPath)
      .sort()
      .map((k) => byPath[k]);
    const gates = body.receipt && body.receipt.check && body.receipt.check.gates;
    if (gates && gates.length) {
      lastWork.gates = gates;
    }
    if (body.product_url || health.product_url) {
      lastWork.product_url = body.product_url || health.product_url;
      productTick += 1;
    }
    lastWork = lastWork;
  }

  async function think(payload) {
    const r = await fetch("/think", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    const body = await r.json();
    return { status: r.status, body };
  }

  async function send() {
    const text = draft.trim();
    if (!text || busy) return;
    draft = "";
    messages = [...messages, { role: "user", text, raw: rawForth }];
    await tick();
    scroll();
    busy = true;
    stopping = false;
    if (rawForth) {
      messages = [...messages, { role: "pending", episode: 1 }];
      try {
        const { status, body } = await think({
          language: "forth",
          program: ensureReceipt(text),
          artifacts: {},
          rationale: "",
        });
        rememberWork(body);
        ping();
        messages = messages.filter((m) => m.role !== "pending");
        messages = [...messages, machineFrom(body, status, 1, ensureReceipt(text))];
      } catch (err) {
        messages = messages.filter((m) => m.role !== "pending");
        messages = [...messages, { role: "machine", ok: false, error: String(err), details: [], changed: [] }];
      }
      busy = false;
      await tick();
      scroll();
      return;
    }
    const maxTurns = once ? 1 : MAX_TURNS;
    let extra = "";
    let episode = 0;
    let lastOk = false;
    let lastBody = null;
    try {
      for (episode = 1; episode <= maxTurns && !stopping; episode += 1) {
        messages = [...messages, { role: "pending", episode }];
        await tick();
        scroll();
        const { status, body } = await think({ extra, goal: text, episode });
        lastBody = body;
        rememberWork(body);
        ping();
        const row = machineFrom(body, status, episode);
        lastOk = row.ok;
        messages = messages.filter((m) => m.role !== "pending");
        messages = [...messages, row];
        await tick();
        scroll();
        const discharged = Boolean(body && body.receipt && claimsDischarged(body.receipt.check));
        if (stopping || discharged || episode >= maxTurns) break;
        extra = extraFrom(body);
      }
      if (episode > 1 || lastOk || lastBody) {
        const discharged = Boolean(
          lastBody && lastBody.receipt && claimsDischarged(lastBody.receipt.check)
        );
        messages = [
          ...messages,
          {
            role: "done",
            ok: lastOk && discharged,
            episodes: Math.min(episode, maxTurns),
            stopped: stopping || (episode >= maxTurns && !discharged),
          },
        ];
      }
    } catch (err) {
      messages = messages.filter((m) => m.role !== "pending");
      messages = [...messages, { role: "machine", ok: false, error: String(err), details: [], changed: [] }];
    }
    busy = false;
    stopping = false;
    await tick();
    scroll();
  }

  function onKey(ev) {
    if (ev.key === "Enter" && !ev.shiftKey) {
      ev.preventDefault();
      send();
    }
  }

  function scroll() {
    if (thread) thread.scrollTop = thread.scrollHeight;
  }

  async function loadEnvelope(ev) {
    const file = ev.target.files && ev.target.files[0];
    ev.target.value = "";
    if (!file) return;
    try {
      const env = JSON.parse(await file.text());
      messages = [...messages, { role: "user", text: "envelope: " + file.name, raw: true }];
      busy = true;
      messages = [...messages, { role: "pending" }];
      const r = await fetch("/think", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(env),
      });
      const body = await r.json();
      rememberWork(body);
      messages = messages.filter((m) => m.role !== "pending");
      messages = [...messages, machineFrom(body, r.status, 1, env.program)];
    } catch (err) {
      messages = messages.filter((m) => m.role !== "pending");
      messages = [...messages, { role: "machine", ok: false, error: String(err), details: [], changed: [] }];
    }
    busy = false;
    await tick();
    scroll();
  }
</script>

<div class="desk">
<div class="shell">
  <header>
    <div>
      <p class="mark">Living Dictionary</p>
      <p class="sub">Forth is the harness. The goal is the product.</p>
    </div>
    <p class="pulse" class:up={health.ok} class:down={!health.ok}>
      {#if health.ok}
        critic {health.critic} · shen {health.shen ? "on" : "off"}
        {#if health.workspace}<br />{health.workspace.replace(/\/+$/, "").split("/").pop()}{/if}
      {:else}
        host down · make openresty-serve
      {/if}
    </p>
  </header>

  <div class="thread" bind:this={thread} aria-live="polite">
    {#if messages.length === 0}
      <div class="empty">
        <p class="lemma">turn <i>n.</i></p>
        <p>Name any software. Forth episodes keep running until goal claims pass. The work pane shows diffs and a live product if this job builds one.</p>
      </div>
    {/if}

    {#each messages as msg}
      {#if msg.role === "user"}
        <article class="row user">
          <div class="bubble">{msg.text}</div>
        </article>
      {:else if msg.role === "pending"}
        <article class="row machine">
          <div class="entry">
            <p class="lemma wait">planning <i>v.</i></p>
            <p class="def">
              Episode {msg.episode || 1}. Grok is writing the next Forth program.
            </p>
          </div>
        </article>
      {:else if msg.role === "done"}
        <article class="row machine">
          <div class="entry" class:ok={msg.ok} class:bad={!msg.ok}>
            <p class="lemma">
              {msg.stopped ? "halt" : "done"}
              <i>{msg.stopped ? "v." : "adj."}</i>
            </p>
            <p class="def">
              {msg.episodes}
              {msg.episodes === 1 ? "episode" : "episodes"}
              {#if msg.stopped}
                — halted (cap or stop). Same goal can continue.
              {:else}
                . Goal claims passed.
              {/if}
            </p>
          </div>
        </article>
      {:else}
        <article class="row machine">
          <div class="entry" class:ok={msg.ok} class:bad={!msg.ok}>
            <p class="lemma">
              {msg.ok ? "accept" : "reject"}
              <i>{msg.ok ? "v." : "n."}</i>
              {#if msg.episode}
                <span class="ep">ep. {msg.episode}</span>
              {/if}
            </p>
            {#if msg.rationale}
              <p class="def">{msg.rationale}</p>
            {/if}
            {#if msg.error}
              <p class="def err">{msg.error}</p>
            {/if}
            {#if msg.details && msg.details.length}
              <ul class="details">
                {#each msg.details as d}<li>{d}</li>{/each}
              </ul>
            {/if}
            {#if msg.artifactKeys && msg.artifactKeys.length}
              <ul class="artifacts">
                {#each msg.artifactKeys as k}<li>{k}</li>{/each}
              </ul>
            {/if}
            {#if msg.gates && msg.gates.length}
              <ul class="gates">
                {#each msg.gates as g}
                  <li class:pass={g.passed} class:fail={!g.passed && !g.skipped}>
                    {g.name}
                    {g.passed ? "pass" : g.skipped ? "skip" : "fail"}
                    {#if g.duration_ms} · {g.duration_ms}ms{/if}
                    {#if g.reason} — {g.reason}{/if}
                  </li>
                {/each}
              </ul>
            {/if}
            {#if msg.program}
              <pre class="forth">{msg.program}</pre>
            {/if}
            <p class="cite">
              {#if msg.model}{msg.model} · {/if}
              {#if msg.changed && msg.changed.length}changed {msg.changed.join(", ")}
              {:else if msg.ok}no files changed{/if}
              {#if msg.defined && msg.defined.length} · words {msg.defined.join(" ")}{/if}
              {#if msg.stack != null} · stack {msg.stack}{/if}
              {#if msg.continuing} · continuing{/if}
            </p>
          </div>
        </article>
      {/if}
    {/each}
  </div>

  <form class="composer" on:submit|preventDefault={send}>
    <textarea
      bind:value={draft}
      on:keydown={onKey}
      rows="2"
      placeholder={busy
        ? "Episodes are running…"
        : rawForth
          ? "S\" path\" READ-FILE"
          : "Name the product"}
      disabled={busy}
    ></textarea>
    <div class="bar">
      <label class="toggle">
        <input type="checkbox" bind:checked={rawForth} disabled={busy} />
        Forth
      </label>
      <label class="toggle" title="One episode, then stop">
        <input type="checkbox" bind:checked={once} disabled={busy || rawForth} />
        Once
      </label>
      <label class="file">
        Envelope
        <input type="file" accept="application/json,.json" on:change={loadEnvelope} disabled={busy} />
      </label>
      {#if busy}
        <button type="button" on:click={() => (stopping = true)}>Stop</button>
      {:else}
        <button type="submit" disabled={!draft.trim()}>Send</button>
      {/if}
    </div>
  </form>
</div>

<aside class="work">
  <header>
    <div>
      <p class="mark">work</p>
      <p class="sub">
        {#if lastWork.product_url || health.product_url}
          live product
        {:else}
          diffs and gates
        {/if}
      </p>
    </div>
  </header>
  {#if lastWork.product_url || health.product_url}
    <iframe
      title="product"
      src="{(lastWork.product_url || health.product_url) + '?t=' + productTick}"
    ></iframe>
  {/if}
  {#if lastWork.gates && lastWork.gates.length}
    <ul class="gates">
      {#each lastWork.gates as g}
        <li class:pass={g.passed} class:fail={!g.passed && !g.skipped}>
          {g.name} {g.passed ? "pass" : g.skipped ? "skip" : "fail"}
          {#if g.reason} — {g.reason}{/if}
        </li>
      {/each}
    </ul>
  {/if}
  {#each lastWork.previews as p}
    <article class="preview">
      <p class="path">{p.path}</p>
      <pre>{p.text}</pre>
    </article>
  {/each}
  {#if !lastWork.product_url && !health.product_url && !(lastWork.previews && lastWork.previews.length)}
    <p class="hint">Changed files and a running product (when the job has one) show up here.</p>
  {/if}
</aside>
</div>

<style>
  .desk {
    height: 100%;
    display: grid;
    grid-template-columns: minmax(22rem, 28rem) 1fr;
  }

  .shell {
    height: 100%;
    min-width: 0;
    display: flex;
    flex-direction: column;
    background: var(--page);
    box-shadow: 1px 0 0 var(--line);
  }

  .work {
    height: 100%;
    min-width: 0;
    display: flex;
    flex-direction: column;
    background: #0f141a;
    color: #e8edf1;
    overflow: auto;
  }
  .work header { border-bottom-color: #2a3340; }
  .work .mark, .work .sub { color: #d5dde4; }
  .work .sub { color: #8b98a5; }
  .work iframe {
    flex: 1;
    width: 100%;
    border: 0;
    background: #fff;
    min-height: 16rem;
  }
  .work .hint {
    margin: 1.25rem;
    color: #8b98a5;
    max-width: 22rem;
  }
  .preview {
    margin: 0.75rem 1rem;
    border: 1px solid #2a3340;
  }
  .preview .path {
    margin: 0;
    padding: 0.35rem 0.55rem;
    font-size: 0.75rem;
    color: #8b98a5;
    border-bottom: 1px solid #2a3340;
  }
  .preview pre {
    margin: 0;
    padding: 0.55rem;
    font-size: 0.72rem;
    white-space: pre-wrap;
    max-height: 14rem;
    overflow: auto;
  }

  @media (max-width: 800px) {
    .desk { grid-template-columns: 1fr; grid-template-rows: 1fr 1fr; }
  }

  header {
    display: flex;
    justify-content: space-between;
    align-items: baseline;
    gap: 1rem;
    padding: 1.1rem 1.25rem 0.85rem;
    border-bottom: 1px solid var(--line);
  }

  .mark {
    margin: 0;
    font-family: Literata, Georgia, serif;
    font-size: 1.35rem;
    font-weight: 600;
    font-optical-sizing: auto;
    letter-spacing: -0.02em;
  }

  .sub {
    margin: 0.15rem 0 0;
    color: var(--mute);
    font-size: 0.88rem;
  }

  .pulse {
    margin: 0;
    font-size: 0.75rem;
    color: var(--mute);
    white-space: nowrap;
  }
  .pulse.up { color: var(--accept); }
  .pulse.down { color: var(--reject); }

  .thread {
    flex: 1;
    overflow: auto;
    padding: 1.25rem 1.25rem 0.5rem;
    display: flex;
    flex-direction: column;
    gap: 0.85rem;
  }

  .empty {
    margin: auto 0;
    max-width: 22rem;
  }

  .empty .lemma {
    font-family: Literata, Georgia, serif;
    font-size: 1.6rem;
    margin: 0 0 0.4rem;
  }

  .empty p { margin: 0; color: var(--mute); line-height: 1.45; }

  .row { display: flex; }
  .row.user { justify-content: flex-end; }
  .row.machine { justify-content: flex-start; }

  .bubble {
    max-width: 85%;
    background: var(--user);
    color: #f3f5f7;
    padding: 0.65rem 0.85rem;
    border-radius: 1rem 1rem 0.25rem 1rem;
    white-space: pre-wrap;
    line-height: 1.4;
  }

  .entry {
    max-width: 92%;
    background: var(--card);
    border: 1px solid var(--line);
    border-left: 3px solid var(--line);
    padding: 0.7rem 0.9rem 0.65rem;
  }
  .entry.ok { border-left-color: var(--accept); }
  .entry.bad { border-left-color: var(--reject); }

  .lemma {
    margin: 0;
    font-family: Literata, Georgia, serif;
    font-size: 1.35rem;
    font-weight: 600;
    letter-spacing: -0.02em;
    line-height: 1.1;
  }
  .entry.ok .lemma { color: var(--accept); }
  .entry.bad .lemma { color: var(--reject); }
  .lemma.wait { color: var(--mute); font-style: italic; font-weight: 500; }
  .lemma i {
    font-size: 0.85rem;
    font-weight: 500;
    color: var(--mute);
    margin-left: 0.35rem;
  }
  .ep {
    margin-left: 0.45rem;
    font-family: Outfit, system-ui, sans-serif;
    font-size: 0.72rem;
    font-weight: 500;
    color: var(--mute);
    letter-spacing: 0.02em;
  }

  .def { margin: 0.35rem 0 0; line-height: 1.45; }
  .def.err { color: var(--reject); }

  .details {
    margin: 0.4rem 0 0;
    padding-left: 1.1rem;
    color: var(--reject);
    font-size: 0.88rem;
  }

  .artifacts {
    margin: 0.4rem 0 0;
    padding-left: 1.1rem;
    font-size: 0.82rem;
    font-family: "IBM Plex Mono", ui-monospace, monospace;
    color: var(--mute);
  }

  .gates {
    margin: 0.45rem 0 0;
    padding-left: 1.1rem;
    font-size: 0.82rem;
    font-family: "IBM Plex Mono", ui-monospace, monospace;
  }
  .gates .pass { color: var(--accept); }
  .gates .fail { color: var(--reject); }

  .forth {
    margin: 0.55rem 0 0;
    padding: 0.55rem 0.65rem;
    background: #e8edf1;
    color: var(--ink);
    font-family: "IBM Plex Mono", ui-monospace, monospace;
    font-size: 0.78rem;
    line-height: 1.45;
    white-space: pre-wrap;
    overflow-x: auto;
  }

  .cite {
    margin: 0.45rem 0 0;
    font-size: 0.75rem;
    color: var(--mute);
  }

  .composer {
    border-top: 1px solid var(--line);
    padding: 0.75rem 1.25rem 1rem;
    background: var(--page);
  }

  textarea {
    width: 100%;
    resize: none;
    border: 1px solid var(--line);
    background: var(--card);
    color: var(--ink);
    padding: 0.65rem 0.75rem;
    border-radius: 0.15rem;
    min-height: 3.4rem;
  }

  .bar {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    margin-top: 0.5rem;
  }

  .toggle, .file {
    font-size: 0.8rem;
    color: var(--mute);
    display: flex;
    align-items: center;
    gap: 0.35rem;
    cursor: pointer;
  }

  .file input { display: none; }
  .file { text-decoration: underline; text-underline-offset: 0.15em; }

  button[type="submit"] {
    margin-left: auto;
    background: var(--copper);
    color: #fffaf6;
    border: 0;
    padding: 0.45rem 1rem;
    border-radius: 999px;
    font-weight: 500;
    cursor: pointer;
  }
  button[type="submit"]:disabled {
    opacity: 0.45;
    cursor: not-allowed;
  }

  @media (max-width: 640px) {
    header { flex-direction: column; align-items: flex-start; gap: 0.35rem; }
    .bubble, .entry { max-width: 100%; }
  }
</style>
