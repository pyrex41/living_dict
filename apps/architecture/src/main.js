import './styles.css';

const sourceRoot = 'https://github.com/pyrex41/living_dict/blob/main/';

const stages = [
  {
    id: 'observe', number: '01', name: 'Observe', owner: 'Model, bounded', tone: 'amber',
    summary: 'The model asks focused questions through read-only repository tools.',
    detail: 'OODA research can list, search, and read a bounded amount of evidence. Its results become planner context, but they carry no write authority.',
    input: 'Goal + workspace manifest', output: 'Research brief + evidence hashes', model: 'yes', mutation: 'no',
    source: 'beam/lib/ld_host/research.ex'
  },
  {
    id: 'plan', number: '02', name: 'Plan', owner: 'Model', tone: 'amber',
    summary: 'One model call proposes an envelope, not a stream of mutations.',
    detail: 'The envelope contains complete artifact bodies, a Forth control program, and an inert rationale. At this point nothing in the workspace has changed.',
    input: 'Goal + observation + feedback', output: '{ program, artifacts, rationale }', model: 'yes', mutation: 'no',
    source: 'beam/lib/ld_host/planner.ex'
  },
  {
    id: 'critic', number: '03', name: 'Critic', owner: 'Typed Shen', tone: 'violet',
    summary: 'A deterministic abstract interpreter checks the whole proposed program.',
    detail: 'It evaluates stack shape, effects, path globs, artifacts, control structure, and typed dictionary calls. Rejection returns structured errors; it never edits files or asks a model.',
    input: 'Program + policy + catalog', output: 'Accept(depth, effects) or Reject(errors)', model: 'no', mutation: 'no',
    source: 'shen/critic/validate.shen'
  },
  {
    id: 'execute', number: '04', name: 'Execute', owner: 'BEAM + Forth VM', tone: 'green',
    summary: 'Only an accepted program receives host capabilities.',
    detail: 'The Forth VM orders artifact installation and host calls. Workspace confinement is checked again at the capability boundary. The model is not running while these words execute.',
    input: 'Accepted program + artifacts', output: 'Mutations + traps + actual word use', model: 'no', mutation: 'yes',
    source: 'beam/lib/ld_host/forth.ex'
  },
  {
    id: 'judge', number: '05', name: 'Judge', owner: 'Frozen contract', tone: 'blue',
    summary: 'Executable claims—not model confidence—decide whether the task is done.',
    detail: 'Builds, tests, commands, and probes run with bounded time. Judge provenance says whether the contract was approved/hidden or merely model-authored.',
    input: 'Workspace + approved claims', output: 'Discharge report', model: 'no', mutation: 'measured',
    source: 'beam/lib/ld_host/gates.ex'
  },
  {
    id: 'record', number: '06', name: 'Record', owner: 'Ledger', tone: 'blue',
    summary: 'The run leaves a hash-sequenced account rather than asking you to trust a transcript.',
    detail: 'Plans, critic verdicts, mutations, gate results, cache evidence, and receipts are append-only events. Content-addressed tree hashes make before/after state auditable.',
    input: 'Runtime events', output: 'events.jsonl + trace.jsonl + receipt', model: 'no', mutation: 'run state only',
    source: 'beam/lib/ld_host/ledger.ex'
  }
];

const forthSteps = [
  { line: 1, code: 'S" registry.py"', stack: ['registry.py'], effect: 'Push a string. No I/O.' },
  { line: 2, code: 'USE-ARTIFACT', stack: ['<259 bytes>'], effect: 'Resolve an artifact already present in the accepted envelope.' },
  { line: 3, code: 'S" pipeline/registry.py"', stack: ['<259 bytes>', 'pipeline/registry.py'], effect: 'Push the destination path.' },
  { line: 4, code: 'WRITE-FILE', stack: ['true'], effect: 'Host checks the path and writes the bytes. This is real I/O.' },
  { line: 5, code: 'DROP', stack: [], effect: 'Discard the success flag.' },
  { line: 6, code: 'RUN-GATES', stack: ['true'], effect: 'Execute the frozen acceptance contract.' },
  { line: 7, code: 'RECEIPT', stack: ['true'], effect: 'Persist hashes, effects, and changed files.' }
];

const runtimeRows = [
  ['BEAM / OTP host', 'Every live run', 'Owns the loop, supervision, timeouts, and process isolation.', 'beam/lib/ld_host/run.ex'],
  ['Forth VM', 'Every accepted episode', 'Actually dispatches host capabilities; not a prompt decoration.', 'beam/lib/ld_host/forth.ex'],
  ['Typed Shen critic', 'Every proposed episode', 'Compiled to BEAM bytecode when available; rejects before I/O.', 'shen/critic/validate.shen'],
  ['Gates + approved claims', 'Every episode', 'Measures completion independently of model stopping.', 'beam/lib/ld_host/gates.ex'],
  ['Ledger + receipts', 'Every run', 'Records decisions, mutations, and state hashes.', 'beam/lib/ld_host/ledger.ex'],
  ['OODA research', 'When --ooda auto', 'Bounded read-only context gathering; can be disabled.', 'beam/lib/ld_host/research.ex'],
  ['Warm dictionary', 'When a dictionary is supplied', 'Loads typed words; measured use is distinct from planner mention.', 'beam/lib/ld_host/dictionary.ex'],
  ['Linda + Jido obligations', 'Demo / benchmark orchestration', 'Real leased work coordination, not the direct ld.run hot path.', 'beam/lib/ld_host/obligation.ex'],
  ['OpenResty + browser bodies', 'Alternate deployments', 'Portability proofs sharing critic/ABI—not three layers per run.', 'docs/ARCHITECTURE.md']
];

const app = document.querySelector('#app');
app.innerHTML = `
  <header class="site-nav">
    <a class="brand" href="#top" aria-label="Living Dictionary architecture home">
      <span class="brand-mark">LD</span><span>Living Dictionary</span>
    </a>
    <nav aria-label="Main navigation">
      <a href="#episode">One episode</a><a href="#forth">Forth</a><a href="#critic">Critic</a><a href="#truth">Reality check</a>
    </nav>
    <a class="source-pill" href="${sourceRoot}" target="_blank" rel="noreferrer">View source ↗</a>
  </header>

  <main id="top">
    <section class="hero section-shell">
      <div class="hero-grid grid-lines" aria-hidden="true"></div>
      <div class="hero-copy reveal">
        <p class="kicker"><span class="live-dot"></span> Architecture, with the seams left visible</p>
        <h1>The model proposes.<br><em>The machine decides what runs.</em></h1>
        <p class="hero-lede">Living Dictionary is a coding agent built around an executable boundary: one model-generated plan is inspected as a whole, accepted or rejected by a deterministic critic, then run on BEAM with the model switched off.</p>
        <div class="hero-actions">
          <a class="button primary" href="#episode">Trace an episode <span>↓</span></a>
          <a class="button ghost" href="#objection">Is this just dressing?</a>
        </div>
      </div>
      <div class="hero-machine reveal" aria-label="Animated execution boundary diagram">
        <div class="machine-label">LIVE CONTROL PLANE</div>
        <div class="machine-node model-node"><span>probabilistic</span><strong>MODEL</strong><small>research + proposal</small></div>
        <div class="machine-wire"><i></i><code>envelope.json</code></div>
        <div class="machine-gate"><div class="gate-light"></div><span>deterministic boundary</span><strong>CRITIC</strong><b>ACCEPT</b></div>
        <div class="machine-wire accepted"><i></i><code>capability grant</code></div>
        <div class="machine-node host-node"><span>model off</span><strong>BEAM HOST</strong><small>Forth → effects → gates</small></div>
      </div>
      <div class="hero-proofbar reveal">
        <div><span>01</span><p><strong>Before accept</strong>Workspace unchanged</p></div>
        <div><span>02</span><p><strong>During execute</strong>No model calls</p></div>
        <div><span>03</span><p><strong>At completion</strong>Claims discharged</p></div>
      </div>
    </section>

    <section class="premise section-shell">
      <div class="section-index">00 / PREMISE</div>
      <div class="premise-copy reveal"><h2>A control plane, not a smarter model.</h2><p>Codex and Pi usually let a model choose the next action in a live tool loop. Living Dictionary moves the trust boundary: observation may be probabilistic, but authorization, execution, and judgment have non-model owners.</p></div>
      <div class="boundary-card reveal"><div class="boundary-head"><span>WHERE TRUST CHANGES</span><span class="mono">proposal ≠ permission</span></div><div class="boundary-scale"><span>reason</span><span>research</span><i></i><b>CRITIC</b><i></i><span>execute</span><span>judge</span></div></div>
    </section>

    <section id="episode" class="episode section-shell">
      <div class="section-heading reveal"><div><p class="kicker">01 / ONE REAL EPISODE</p><h2>Follow authority as it moves.</h2></div><p>Click each stage. Notice where the model disappears—and where the first write becomes possible.</p></div>
      <div class="stage-tabs" role="tablist">${stages.map((s, i) => `<button role="tab" aria-selected="${i === 0}" data-stage="${s.id}" class="stage-tab ${i === 0 ? 'active' : ''}"><span>${s.number}</span><b>${s.name}</b><i></i></button>`).join('')}</div>
      <article class="stage-detail reveal" id="stage-detail"></article>
    </section>

    <section id="forth" class="forth-section section-shell dark-panel">
      <div class="section-heading light reveal"><div><p class="kicker">02 / WHAT THE FORTH DOES</p><h2>Small language.<br>Real authority.</h2></div><p>Forth is not where the model hides the source code. Artifact bodies live in the envelope. Forth makes ordering, stack shape, and effects explicit enough to validate before execution.</p></div>
      <div class="forth-lab reveal">
        <div class="code-window">
          <div class="window-bar"><span><i></i><i></i><i></i></span><b>episode.forth</b><em>accepted program</em></div>
          <ol class="code-lines">${forthSteps.map((s, i) => `<li data-step="${i}"><button><span>${s.code}</span></button></li>`).join('')}</ol>
        </div>
        <div class="vm-panel">
          <div class="vm-head"><span>VM INSPECTOR</span><span id="vm-counter">STEP 1 / 7</span></div>
          <div class="vm-effect"><span>instruction</span><code id="vm-code"></code><p id="vm-effect"></p></div>
          <div class="stack-wrap"><span>DATA STACK</span><div id="vm-stack" class="stack"></div></div>
          <div class="vm-controls"><button id="vm-prev" aria-label="Previous Forth instruction">←</button><button id="vm-next">Step VM <span>→</span></button></div>
        </div>
      </div>
      <div class="forth-note reveal"><strong>Why not JSON alone?</strong><p>A schema can validate shape. The tiny program also exposes control flow, stack effects, and the exact order of capability calls. The critic can reason about composition without executing the change.</p><a href="${sourceRoot}beam/lib/ld_host/forth.ex" target="_blank" rel="noreferrer">Read the  VM source ↗</a></div>
    </section>

    <section id="critic" class="critic-section section-shell">
      <div class="critic-grid">
        <div class="critic-copy reveal"><p class="kicker">03 / THE DETERMINISTIC CRITIC</p><h2>General does not have to mean generative.</h2><p>The critic does not know how to build your application. It knows the semantics of the plan language and receives the task's policy as data.</p><p>That is the same reason a compiler type-checker can validate programs it has never seen. The rules are fixed; the program, artifact set, allowed paths, effects, and typed catalog are inputs.</p><a class="text-link" href="${sourceRoot}shen/critic/validate.shen" target="_blank" rel="noreferrer">Inspect the typed Shen source ↗</a></div>
        <div class="critic-console reveal">
          <div class="console-top"><span>CRITIC / ABSTRACT INTERPRETER</span><div class="switch"><button class="active" data-verdict="accept">Accept</button><button data-verdict="reject">Reject</button></div></div>
          <div id="critic-program" class="critic-program"></div>
          <div class="critic-rules"><div><span>STACK</span><b id="rule-stack"></b></div><div><span>EFFECTS</span><b id="rule-effects"></b></div><div><span>PATH</span><b id="rule-path"></b></div><div><span>ARTIFACT</span><b id="rule-artifact"></b></div></div>
          <div id="critic-verdict" class="critic-verdict"></div>
        </div>
      </div>
      <div class="critic-answer reveal"><span class="big-question">?</span><div><strong>“But how can deterministic rules work for arbitrary software?”</strong><p>They do not prove the application is correct. They prove the proposed <em>effects are well-formed and authorized</em>. Application correctness comes later from the task-specific executable contract. Policy and outcome are deliberately different checks.</p></div></div>
    </section>

    <section id="beam" class="beam-section section-shell">
      <div class="beam-card reveal">
        <div class="beam-copy"><p class="kicker">04 / WHAT BEAM DOES</p><h2>The runtime is the product boundary.</h2><p>BEAM is not the planner. It owns the parts that should survive an unreliable planner: supervision, bounded retries, timers, critic service, VM execution, gate processes, ledgers, and—when benchmarking—leased obligations.</p><div class="beam-tags"><span>supervision</span><span>timeouts</span><span>single-writer ledger</span><span>lease fencing</span><span>crash isolation</span></div></div>
        <div class="beam-orbit" aria-hidden="true"><div class="beam-core">BEAM<small>live host</small></div><span style="--i:0">RUN</span><span style="--i:1">VM</span><span style="--i:2">GATES</span><span style="--i:3">LEDGER</span><span style="--i:4">CRITIC</span><span style="--i:5">OTP</span></div>
      </div>
    </section>

    <section id="truth" class="truth-section section-shell">
      <div class="section-heading reveal"><div><p class="kicker">05 / ARE WE REALLY USING IT?</p><h2>The hot-path ledger.</h2></div><p>No architecture-by-association. This table distinguishes what every live run executes from conditional mechanisms and alternate deployment bodies.</p></div>
      <div class="truth-table reveal"><div class="truth-row truth-head"><span>Component</span><span>When it runs</span><span>What it owns</span><span>Source</span></div>${runtimeRows.map(([name, when, role, source]) => `<div class="truth-row"><strong>${name}</strong><span><i class="status ${when.startsWith('Every') ? 'hot' : 'conditional'}"></i>${when}</span><p>${role}</p><a href="${sourceRoot}${source}" target="_blank" rel="noreferrer">${source.split('/').pop()} ↗</a></div>`).join('')}</div>
    </section>

    <section id="objection" class="objection section-shell">
      <div class="objection-card reveal">
        <p class="kicker">06 / THE ONE-SHOT OBJECTION</p><h2>Yes, the model still generates the solution.</h2><p class="objection-lede">Living Dictionary does not replace model intelligence. On an easy task, a strong model may emit the right files in one shot—and the control program can look thin.</p>
        <div class="honesty-grid"><div><span>What the architecture adds</span><ul><li>No mutation before whole-plan validation</li><li>Explicit, bounded capability order</li><li>Independent completion evidence</li><li>Replayable state and failure provenance</li><li>A typed path for demonstrated reuse</li></ul></div><div><span>What it does not magically add</span><ul><li>A proof that generated application logic is correct</li><li>Guaranteed benefit on trivial one-shot tasks</li><li>Measured dictionary lift before the new campaign</li><li>Zero stochastic variance or provider latency</li><li>Equal maturity across every runtime body</li></ul></div></div>
        <div class="testable-claim"><span>THE TESTABLE CLAIM</span><p>Not “Forth writes better code.” The claim is that separating proposal, authorization, execution, and judgment can preserve correctness with fewer model-in-the-loop actions—and leave stronger evidence when something fails.</p></div>
      </div>
    </section>

    <section class="proof-section section-shell">
      <p class="kicker reveal">07 / DON'T TAKE THE PAGE'S WORD FOR IT</p><h2 class="reveal">Read the seams.</h2>
      <div class="proof-links reveal"><a href="${sourceRoot}beam/lib/ld_host/run.ex" target="_blank" rel="noreferrer"><span>Kernel loop</span><strong>run.ex</strong><i>↗</i></a><a href="${sourceRoot}shen/critic/validate.shen" target="_blank" rel="noreferrer"><span>Critic source</span><strong>validate.shen</strong><i>↗</i></a><a href="${sourceRoot}beam/lib/ld_host/forth.ex" target="_blank" rel="noreferrer"><span>Interpreter</span><strong>forth.ex</strong><i>↗</i></a><a href="${sourceRoot}docs/design/LATEST_BENCHMARK_CAMPAIGN.md" target="_blank" rel="noreferrer"><span>Falsification plan</span><strong>latest campaign</strong><i>↗</i></a></div>
    </section>
  </main>
  <footer><div class="brand"><span class="brand-mark">LD</span><span>Living Dictionary</span></div><p>Architecture should constrain the system, not decorate the pitch.</p><a href="#top">Back to top ↑</a></footer>
`;

let activeStage = 0;
const detail = document.querySelector('#stage-detail');
function renderStage(index) {
  activeStage = index;
  const s = stages[index];
  document.querySelectorAll('.stage-tab').forEach((el, i) => { el.classList.toggle('active', i === index); el.setAttribute('aria-selected', String(i === index)); });
  detail.innerHTML = `<div class="stage-number ${s.tone}">${s.number}</div><div class="stage-copy"><p class="stage-owner">OWNER / ${s.owner}</p><h3>${s.summary}</h3><p>${s.detail}</p><a href="${sourceRoot}${s.source}" target="_blank" rel="noreferrer">Open ${s.source.split('/').pop()} ↗</a></div><dl class="stage-facts"><div><dt>INPUT</dt><dd>${s.input}</dd></div><div><dt>OUTPUT</dt><dd>${s.output}</dd></div><div><dt>MODEL ACTIVE?</dt><dd class="${s.model === 'yes' ? 'warn' : 'safe'}">${s.model.toUpperCase()}</dd></div><div><dt>CAN MUTATE?</dt><dd class="${s.mutation === 'yes' ? 'warn' : 'safe'}">${s.mutation.toUpperCase()}</dd></div></dl>`;
}
document.querySelectorAll('.stage-tab').forEach((el, i) => el.addEventListener('click', () => renderStage(i)));
renderStage(0);

let vmStep = 0;
function renderVM() {
  const s = forthSteps[vmStep];
  document.querySelector('#vm-counter').textContent = `STEP ${vmStep + 1} / ${forthSteps.length}`;
  document.querySelector('#vm-code').textContent = s.code;
  document.querySelector('#vm-effect').textContent = s.effect;
  document.querySelector('#vm-stack').innerHTML = s.stack.length ? s.stack.map((x, i) => `<div><span>${s.stack.length - i}</span><code>${x.replaceAll('<', '&lt;').replaceAll('>', '&gt;')}</code></div>`).join('') : '<p>— empty —</p>';
  document.querySelectorAll('.code-lines li').forEach((el, i) => el.classList.toggle('active', i === vmStep));
  document.querySelector('#vm-prev').disabled = vmStep === 0;
  document.querySelector('#vm-next').innerHTML = vmStep === forthSteps.length - 1 ? 'Reset <span>↺</span>' : 'Step VM <span>→</span>';
}
document.querySelector('#vm-prev').addEventListener('click', () => { vmStep = Math.max(0, vmStep - 1); renderVM(); });
document.querySelector('#vm-next').addEventListener('click', () => { vmStep = vmStep === forthSteps.length - 1 ? 0 : vmStep + 1; renderVM(); });
document.querySelectorAll('.code-lines li').forEach((el, i) => el.addEventListener('click', () => { vmStep = i; renderVM(); }));
renderVM();

const criticCases = {
  accept: { code: '<i>1</i> S" registry.py" USE-ARTIFACT\n<i>2</i> S" pipeline/registry.py" WRITE-FILE\n<i>3</i> RUN-GATES RECEIPT', rules: ['balanced', 'write · exec', 'pipeline/*.py ✓', 'registry.py ✓'], verdict: '<span>ACCEPT</span><b>depth 0 · effects [write, exec]</b>' },
  reject: { code: '<i>1</i> S" registry.py" USE-ARTIFACT\n<i>2</i> S" tests/test_public.py" WRITE-FILE\n<i>3</i> RUN-GATES RECEIPT', rules: ['balanced', 'write · exec', 'tests/** ✕', 'registry.py ✓'], verdict: '<span>REJECT</span><b>write path forbidden: tests/test_public.py</b>' }
};
function renderCritic(key) {
  const c = criticCases[key];
  document.querySelectorAll('[data-verdict]').forEach(b => b.classList.toggle('active', b.dataset.verdict === key));
  document.querySelector('#critic-program').innerHTML = c.code;
  ['stack','effects','path','artifact'].forEach((id, i) => document.querySelector(`#rule-${id}`).textContent = c.rules[i]);
  const verdict = document.querySelector('#critic-verdict'); verdict.className = `critic-verdict ${key}`; verdict.innerHTML = c.verdict;
}
document.querySelectorAll('[data-verdict]').forEach(b => b.addEventListener('click', () => renderCritic(b.dataset.verdict)));
renderCritic('accept');

const observer = new IntersectionObserver(entries => entries.forEach(entry => { if (entry.isIntersecting) entry.target.classList.add('visible'); }), { threshold: 0.12 });
document.querySelectorAll('.reveal').forEach(el => observer.observe(el));
