const stageTabs = document.querySelectorAll('[data-stage]');
const stagePanels = document.querySelectorAll('[data-stage-panel]');

stageTabs.forEach((tab) => tab.addEventListener('click', () => {
  const id = tab.dataset.stage;
  stageTabs.forEach((candidate) => {
    const active = candidate === tab;
    candidate.classList.toggle('active', active);
    candidate.setAttribute('aria-selected', String(active));
  });
  stagePanels.forEach((panel) => {
    const active = panel.dataset.stagePanel === id;
    panel.hidden = !active;
    panel.classList.toggle('active', active);
  });
}));

const vm = document.querySelector('.vm-panel');
const forthSteps = JSON.parse(vm.dataset.steps);
let vmStep = 0;

function escapeHTML(value) {
  const element = document.createElement('span');
  element.textContent = value;
  return element.innerHTML;
}

function renderVM() {
  const step = forthSteps[vmStep];
  document.querySelector('#vm-counter').textContent = `STEP ${vmStep + 1} / ${forthSteps.length}`;
  document.querySelector('#vm-code').textContent = step.code;
  document.querySelector('#vm-effect').textContent = step.effect;
  document.querySelector('#vm-stack').innerHTML = step.stack.length
    ? step.stack.map((value, index) => `<div><span>${step.stack.length - index}</span><code>${escapeHTML(value)}</code></div>`).join('')
    : '<p>— empty —</p>';
  document.querySelectorAll('.code-lines li').forEach((line, index) => line.classList.toggle('active', index === vmStep));
  document.querySelector('#vm-prev').disabled = vmStep === 0;
  document.querySelector('#vm-next').innerHTML = vmStep === forthSteps.length - 1 ? 'Reset <span>↺</span>' : 'Step VM <span>→</span>';
}

document.querySelector('#vm-prev').addEventListener('click', () => { vmStep = Math.max(0, vmStep - 1); renderVM(); });
document.querySelector('#vm-next').addEventListener('click', () => { vmStep = vmStep === forthSteps.length - 1 ? 0 : vmStep + 1; renderVM(); });
document.querySelectorAll('.code-lines li').forEach((line, index) => line.addEventListener('click', () => { vmStep = index; renderVM(); }));
renderVM();

const criticCases = {
  accept: { code: '<i>1</i> S" registry.py" USE-ARTIFACT\n<i>2</i> S" pipeline/registry.py" WRITE-FILE\n<i>3</i> RUN-GATES RECEIPT', rules: ['balanced', 'write · exec', 'pipeline/*.py ✓', 'registry.py ✓'], verdict: '<span>ACCEPT</span><b>depth 0 · effects [write, exec]</b>' },
  reject: { code: '<i>1</i> S" registry.py" USE-ARTIFACT\n<i>2</i> S" tests/test_public.py" WRITE-FILE\n<i>3</i> RUN-GATES RECEIPT', rules: ['balanced', 'write · exec', 'tests/** ✕', 'registry.py ✓'], verdict: '<span>REJECT</span><b>write path forbidden: tests/test_public.py</b>' }
};

function renderCritic(key) {
  const criticCase = criticCases[key];
  document.querySelectorAll('[data-verdict]').forEach((button) => button.classList.toggle('active', button.dataset.verdict === key));
  document.querySelector('#critic-program').innerHTML = criticCase.code;
  ['stack', 'effects', 'path', 'artifact'].forEach((id, index) => { document.querySelector(`#rule-${id}`).textContent = criticCase.rules[index]; });
  const verdict = document.querySelector('#critic-verdict');
  verdict.className = `critic-verdict ${key}`;
  verdict.innerHTML = criticCase.verdict;
}

document.querySelectorAll('[data-verdict]').forEach((button) => button.addEventListener('click', () => renderCritic(button.dataset.verdict)));
renderCritic('accept');

const observer = new IntersectionObserver((entries) => entries.forEach((entry) => {
  if (entry.isIntersecting) entry.target.classList.add('visible');
}), { threshold: 0.12 });
document.querySelectorAll('.reveal').forEach((element) => observer.observe(element));
