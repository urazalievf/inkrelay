/// The review page: one card at a time, Done or Later, keyboard and swipe. Self-contained, no network beyond the local server.
enum ReviewPage {
    static let html = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <meta name="color-scheme" content="light dark">
    <title>Ink Stack</title>
    <style>
    :root {
      --bg: #f2efe8; --card: #fffdf9; --paper: #ffffff; --ink: #1c1b19; --muted: #6d685f; --faint: #a39d92;
      --line: #e4dfd4; --accent: #2e5b4e; --accent-ink: #ffffff; --accent-soft: #e3ece8; --danger: #a8402f;
      --shadow: 0 1px 2px rgba(40, 32, 20, .06), 0 18px 40px -12px rgba(40, 32, 20, .18);
      --radius: 20px; --serif: ui-serif, "New York", "Iowan Old Style", Georgia, serif;
      --sans: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
    }
    @media (prefers-color-scheme: dark) {
      :root:not([data-theme="light"]) {
        --bg: #151513; --card: #201f1c; --paper: #f0f0f0; --ink: #ecebe5; --muted: #a29d93; --faint: #6f6b63;
        --line: #33312c; --accent: #86c2ad; --accent-ink: #0f1f1a; --accent-soft: #23302b; --danger: #e08b7a;
        --shadow: 0 1px 2px rgba(0, 0, 0, .5), 0 18px 40px -12px rgba(0, 0, 0, .6);
      }
    }
    * { box-sizing: border-box; }
    [hidden] { display: none !important; }
    html, body { margin: 0; background: var(--bg); color: var(--ink); font: 16px/1.5 var(--sans); -webkit-font-smoothing: antialiased; }
    body { min-height: 100vh; min-height: 100dvh; display: flex; flex-direction: column; }
    header { display: flex; align-items: baseline; justify-content: space-between; gap: 12px; padding: 20px 20px 0; max-width: 640px; width: 100%; margin: 0 auto; }
    .mark { font: 600 1.05rem/1 var(--serif); letter-spacing: .01em; }
    .mark span { color: var(--muted); font-weight: 400; }
    .count { color: var(--muted); font-size: .875rem; font-variant-numeric: tabular-nums; }
    .progress { height: 3px; background: var(--line); border-radius: 3px; overflow: hidden; max-width: 600px; width: calc(100% - 40px); margin: 14px auto 0; }
    .progress i { display: block; height: 100%; width: 0; background: var(--accent); transition: width .3s ease; }
    main { flex: 1; display: flex; align-items: flex-start; justify-content: center; padding: 18px 16px 24px; }
    .card { width: 100%; max-width: 600px; background: var(--card); border-radius: var(--radius); box-shadow: var(--shadow); overflow: hidden;
      transition: transform .2s ease, opacity .2s ease; touch-action: pan-y; }
    .card.leaving-done { transform: translateX(40px) rotate(1.5deg); opacity: 0; }
    .card.leaving-later { transform: translateX(-40px) rotate(-1.5deg); opacity: 0; }
    .card.entering { opacity: 0; transform: translateY(8px); }
    .paper { background: var(--paper); margin: 14px 14px 0; border-radius: 12px; border: 1px solid var(--line); display: flex; justify-content: center; overflow: hidden; }
    .paper img { display: block; max-width: 100%; height: auto; max-height: 60vh; max-height: 60dvh; width: auto; }
    @media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) .paper img { filter: brightness(.94); } }
    .paper.todo { min-height: 220px; padding: 36px 28px; justify-content: flex-start; align-items: center; color: #1c1b19; }
    .todo-line { display: flex; gap: 14px; align-items: flex-start; font: 400 1.45rem/1.35 var(--serif); }
    .event-mark { flex: none; font-size: 1.1em; line-height: 1.2; }
    .todo-box { flex: none; width: 1.1em; height: 1.1em; margin-top: .14em; border: 2px solid #1c1b19; border-radius: 5px; }
    .body { padding: 16px 20px 6px; }
    .meta { display: flex; gap: 8px; align-items: center; color: var(--muted); font-size: .8125rem; flex-wrap: wrap; }
    .badge { background: var(--accent-soft); color: var(--accent); border-radius: 999px; padding: 2px 9px; font-weight: 600; font-size: .75rem; letter-spacing: .02em; text-transform: uppercase; }
    h1 { font: 600 1.35rem/1.25 var(--serif); margin: 8px 0 4px; overflow-wrap: anywhere; }
    .text { color: var(--ink); white-space: pre-wrap; margin: 8px 0 0; font-size: .95rem; overflow-wrap: anywhere; }
    .text.clamped { display: -webkit-box; -webkit-line-clamp: 3; -webkit-box-orient: vertical; overflow: hidden; }
    .toggle { background: none; border: 0; padding: 4px 0; color: var(--accent); font: inherit; font-size: .875rem; cursor: pointer; }
    .actions { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; padding: 14px 20px 20px; }
    button.act { font: 600 1rem/1 var(--sans); border-radius: 14px; padding: 15px 0; cursor: pointer; border: 1px solid var(--line); background: transparent; color: var(--ink);
      transition: transform .08s ease, background .15s ease; }
    button.act:active { transform: scale(.98); }
    button.act.primary { background: var(--accent); color: var(--accent-ink); border-color: var(--accent); }
    button.act:focus-visible, .toggle:focus-visible, .nav button:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
    .nav { display: flex; justify-content: space-between; align-items: center; max-width: 600px; margin: 0 auto; width: 100%; padding: 0 20px 22px; color: var(--faint); font-size: .8125rem; }
    .nav button { background: none; border: 1px solid var(--line); color: var(--muted); border-radius: 10px; width: 40px; height: 34px; cursor: pointer; font-size: 1rem; }
    .nav button:disabled { opacity: .35; cursor: default; }
    kbd { font: 500 .75rem var(--sans); border: 1px solid var(--line); border-bottom-width: 2px; border-radius: 5px; padding: 0 5px; color: var(--muted); }
    .empty { text-align: center; max-width: 380px; margin: 9vh auto 0; padding: 0 16px; }
    .empty .tick { width: 64px; height: 64px; border-radius: 50%; background: var(--accent-soft); color: var(--accent); display: grid; place-items: center; margin: 0 auto 18px; font-size: 28px; }
    .empty h2 { font: 600 1.4rem/1.3 var(--serif); margin: 0 0 6px; }
    .empty p { color: var(--muted); margin: 0; }
    .toast { position: fixed; left: 50%; bottom: 24px; transform: translateX(-50%); background: var(--ink); color: var(--bg); padding: 10px 16px; border-radius: 12px; font-size: .875rem;
      opacity: 0; pointer-events: none; transition: opacity .2s ease; max-width: calc(100% - 32px); }
    .toast.show { opacity: 1; }
    @media (max-width: 520px) { .hints { display: none; } h1 { font-size: 1.2rem; } }
    @media (prefers-reduced-motion: reduce) { .card, .progress i, button.act { transition: none; } }
    </style>
    </head>
    <body>
    <header><div class="mark">Ink stack <span id="date"></span></div><div class="count" id="count" aria-live="polite"></div></header>
    <div class="progress" aria-hidden="true"><i id="bar"></i></div>
    <main id="main"></main>
    <div class="nav" id="nav" hidden>
      <button id="prev" aria-label="Previous card">←</button>
      <span class="hints"><kbd>D</kbd> done · <kbd>L</kbd> later · <kbd>T</kbd> text · <kbd>←</kbd><kbd>→</kbd> browse</span>
      <button id="next" aria-label="Next card">→</button>
    </div>
    <div class="toast" id="toast" role="status"></div>
    <script>
    const state = { cards: [], index: 0, due: 0, done: 0, busy: false, expanded: false };
    const $ = (id) => document.getElementById(id);
    const el = (tag, cls, text) => { const n = document.createElement(tag); if (cls) n.className = cls; if (text != null) n.textContent = text; return n; };

    async function load() {
      try {
        const reply = await fetch('/api/stack', { cache: 'no-store' });
        const data = await reply.json();
        state.cards = data.cards; state.due = data.due; state.index = 0; state.done = 0;
        $('date').textContent = '· ' + data.date;
        render(true);
      } catch (e) { toast("Can't reach InkRelay. Is `inkrelay watch` running?"); }
    }

    function render(entering) {
      const main = $('main'); main.replaceChildren();
      const total = state.done + state.cards.length;
      $('bar').style.width = total ? (100 * state.done / total) + '%' : '0';
      $('count').textContent = state.cards.length ? `${state.index + 1} of ${state.cards.length}` + (state.due > state.cards.length ? ` · ${state.due - state.cards.length} more tomorrow` : '') : '';
      $('nav').hidden = !state.cards.length;
      if (!state.cards.length) { main.append(emptyState()); return; }
      $('prev').disabled = state.index === 0;
      $('next').disabled = state.index >= state.cards.length - 1;
      const card = state.cards[state.index];
      const node = el('article', 'card' + (entering ? ' entering' : ''));
      node.setAttribute('aria-label', card.title);
      const paper = el('div', 'paper' + (card.kind !== 'page' ? ' todo' : ''));
      if (card.image) {
        const img = el('img'); img.src = card.image; img.alt = 'Page: ' + card.title; img.decoding = 'async'; paper.append(img);
      } else {
        const line = el('div', 'todo-line');
        line.append(card.kind === 'event' ? el('span', 'event-mark', '◷') : el('span', 'todo-box'), el('span', null, card.text || card.title));
        paper.append(line);
      }
      const body = el('div', 'body');
      const meta = el('div', 'meta');
      const badge = card.kind === 'todo' ? 'To-do' : card.kind === 'event' ? 'Event?' : (card.reviews ? 'Again' : 'New');
      meta.append(el('span', 'badge', badge), el('span', null, card.subtitle));
      body.append(meta, el('h1', null, card.title));
      if (card.kind === 'page') {
        const text = el('p', 'text' + (state.expanded ? '' : ' clamped'), card.text || 'No text recognized on this page.');
        body.append(text);
        if ((card.text || '').length > 160 || (card.text || '').split('\n').length > 3) {
          const t = el('button', 'toggle', state.expanded ? 'Show less' : 'Show all text');
          t.onclick = () => { state.expanded = !state.expanded; render(false); };
          body.append(t);
        }
      }
      const actions = el('div', 'actions');
      if (card.kind === 'event') {
        const dismiss = el('button', 'act', 'Dismiss'); dismiss.onclick = () => act('done');
        const add = el('button', 'act primary', 'Add to calendar'); add.onclick = () => act('accept');
        actions.append(dismiss, add);
      } else {
        const later = el('button', 'act', 'Later'); later.onclick = () => act('later');
        const done = el('button', 'act primary', 'Done'); done.onclick = () => act('done');
        actions.append(later, done);
      }
      node.append(paper, body, actions);
      swipe(node);
      main.append(node);
      if (entering) requestAnimationFrame(() => requestAnimationFrame(() => node.classList.remove('entering')));
    }

    function emptyState() {
      const box = el('section', 'empty');
      box.append(el('div', 'tick', '✓'), el('h2', null, 'All caught up'),
        el('p', null, 'New pages and to-dos land here as your tablet syncs. Snoozed cards come back tomorrow morning.'));
      return box;
    }

    async function act(action) {
      const card = state.cards[state.index];
      if (!card || state.busy) return;
      state.busy = true;
      const node = document.querySelector('.card');
      if (node) node.classList.add(action === 'done' ? 'leaving-done' : 'leaving-later');
      try {
        const reply = await fetch(`/api/cards/${card.id}/${action}`, { method: 'POST', headers: { 'X-InkRelay': '1' } });
        if (!reply.ok) { const why = await reply.json().catch(() => ({})); throw new Error(why.error || ''); }
        await new Promise((r) => setTimeout(r, matchMedia('(prefers-reduced-motion: reduce)').matches ? 0 : 160));
        state.cards.splice(state.index, 1); state.due = Math.max(0, state.due - 1); state.done += 1; state.expanded = false;
        if (state.index >= state.cards.length) state.index = Math.max(0, state.cards.length - 1);
        if (action === 'later') toast('Back tomorrow');
        if (action === 'accept') toast('Added to your calendar');
      } catch (e) { toast(e.message || "Couldn't save that. Try again."); if (node) node.classList.remove('leaving-done', 'leaving-later'); state.busy = false; return; }
      state.busy = false;
      render(true);
    }

    function move(step) {
      const next = state.index + step;
      if (next < 0 || next >= state.cards.length) return;
      state.index = next; state.expanded = false; render(true);
    }

    function swipe(node) {
      let x0 = null, dx = 0;
      node.addEventListener('pointerdown', (e) => { if (e.pointerType !== 'mouse') { x0 = e.clientX; dx = 0; } });
      node.addEventListener('pointermove', (e) => { if (x0 == null) return; dx = e.clientX - x0; node.style.transform = `translateX(${dx * .6}px) rotate(${dx / 60}deg)`; });
      const end = () => { if (x0 == null) return; node.style.transform = ''; if (dx > 90) act('done'); else if (dx < -90) act('later'); x0 = null; };
      node.addEventListener('pointerup', end); node.addEventListener('pointercancel', end);
    }

    let toastTimer;
    function toast(message) { const t = $('toast'); t.textContent = message; t.classList.add('show'); clearTimeout(toastTimer); toastTimer = setTimeout(() => t.classList.remove('show'), 2200); }

    $('prev').onclick = () => move(-1);
    $('next').onclick = () => move(1);
    document.addEventListener('keydown', (e) => {
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      const key = e.key.toLowerCase();
      const current = state.cards[state.index];
      if (key === 'a' && current && current.kind === 'event') { act('accept'); }
      else if (key === 'd' || key === 'enter') { e.preventDefault(); act('done'); }
      else if (key === 'l') act('later');
      else if (key === 'arrowright' || key === 'j') move(1);
      else if (key === 'arrowleft' || key === 'k') move(-1);
      else if (key === 't') { state.expanded = !state.expanded; render(false); }
    });
    addEventListener('focus', () => { if (!state.cards.length) load(); });
    load();
    </script>
    </body>
    </html>
    """#
}
