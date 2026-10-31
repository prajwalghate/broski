// Small touches for Broski's site. Everything works without this file.
(() => {
  // A hairline under the header once the page has scrolled.
  const header = document.querySelector('.site-header');
  if (header) {
    const onScroll = () => header.classList.toggle('scrolled', window.scrollY > 4);
    onScroll();
    window.addEventListener('scroll', onScroll, { passive: true });
  }

  // A link to a question opens it.
  const openDetails = (id) => {
    const target = id && document.getElementById(id);
    if (target && target.tagName === 'DETAILS') target.open = true;
  };
  openDetails(decodeURIComponent(location.hash.slice(1)));
  document.addEventListener('click', (event) => {
    const link = event.target.closest && event.target.closest('a[href^="#"]');
    if (link) openDetails(decodeURIComponent(link.getAttribute('href').slice(1)));
  });

  // The questions page: typing narrows the list to questions holding every word.
  const search = document.querySelector('[data-faq-search]');
  if (search) {
    const input = search.querySelector('input');
    const none = document.querySelector('[data-faq-none]');
    const groups = [...document.querySelectorAll('[data-faq-group]')];
    search.hidden = false;
    input.addEventListener('input', () => {
      const words = input.value.toLowerCase().split(/\s+/).filter(Boolean);
      let shown = 0;
      for (const group of groups) {
        let inGroup = 0;
        for (const item of group.querySelectorAll('details')) {
          const match = words.every((word) => item.textContent.toLowerCase().includes(word));
          item.hidden = !match;
          inGroup += match;
        }
        group.hidden = inGroup === 0;
        shown += inGroup;
      }
      none.hidden = shown > 0;
    });
  }

  // A guide's side list marks the section being read.
  const side = document.querySelector('.toc-side');
  if (side && 'IntersectionObserver' in window) {
    const links = new Map([...side.querySelectorAll('a')].map((a) => [a.getAttribute('href').slice(1), a]));
    const reading = new IntersectionObserver((entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        for (const a of links.values()) a.classList.remove('here');
        links.get(entry.target.id).classList.add('here');
      }
    }, { rootMargin: '-80px 0px -70% 0px' });
    for (const id of links.keys()) {
      const heading = document.getElementById(id);
      if (heading) reading.observe(heading);
    }
  }

  // Long pages get a way back to the top.
  if (document.documentElement.scrollHeight > window.innerHeight * 3) {
    const top = document.createElement('a');
    top.className = 'to-top';
    top.href = '#top';
    top.setAttribute('aria-label', 'Back to the top');
    top.innerHTML = '<svg class="icon" aria-hidden="true" focusable="false"><use href="#i-arrow"/></svg>';
    if (!document.getElementById('i-arrow')) top.textContent = '↑';
    document.body.append(top);
    const onScroll = () => top.classList.toggle('shown', window.scrollY > window.innerHeight * 1.2);
    onScroll();
    window.addEventListener('scroll', onScroll, { passive: true });
  }

  // Everything below moves, so none of it runs for a reader who prefers less motion.
  if (!('IntersectionObserver' in window) || window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;

  // The hero's conversation plays round after round while it's on screen.
  const demo = document.querySelector('[data-demo]');
  if (demo) playDemo(demo);

  // What starts below the fold fades in as it arrives.
  const observer = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      entry.target.classList.add('revealed');
      observer.unobserve(entry.target);
    }
  }, { rootMargin: '0px 0px -6% 0px', threshold: 0.06 });
  for (const element of document.querySelectorAll('[data-reveal]')) {
    if (element.getBoundingClientRect().top < window.innerHeight) continue;
    element.classList.add('reveal');
    observer.observe(element);
  }

  function playDemo(demo) {
    const step = (name) => demo.querySelector(`[data-step="${name}"]`);
    const float = (name) => demo.parentElement.querySelector(`[data-float="${name}"]`);
    const input = demo.querySelector('[data-demo-input]');
    const composer = demo.querySelector('.demo-composer');
    const save = demo.querySelector('[data-demo-save]');
    const model = demo.querySelector('[data-demo-model]');
    const card = step('card');
    const reply = step('reply');
    const placeholder = input.textContent;
    const models = ['Claude', 'OpenAI', 'Gemini', 'Ollama']; // any provider: the role's model changes each round
    const dots = document.createElement('span');
    dots.className = 'demo-dots';
    dots.append(...[0, 1, 2].map(() => document.createElement('span')));
    reply.append(dots);

    const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
    const show = (element) => element.classList.remove('off');
    const say = async (text) => {
      composer.classList.add('listening');
      input.classList.add('typing');
      input.textContent = '';
      for (const character of text) {
        input.textContent += character;
        await wait(26);
      }
      await wait(380);
      composer.classList.remove('listening');
      input.classList.remove('typing');
      input.textContent = placeholder;
    };

    const play = async (round) => {
      demo.classList.add('playing');
      for (const element of demo.querySelectorAll('[data-step]')) element.classList.add('off');
      for (const name of ['decision', 'todo']) float(name).classList.add('off');
      card.classList.remove('gone');
      save.classList.remove('pressed');
      model.textContent = models[round % models.length];
      await wait(800);
      await say(step('ask').textContent);
      show(step('ask'));
      await wait(450);
      reply.classList.add('thinking');
      show(reply);
      float('note').classList.add('lit');
      await wait(1400);
      reply.classList.remove('thinking');
      await wait(2800);
      float('note').classList.remove('lit');
      await say(step('answer').textContent);
      show(step('answer'));
      await wait(900);
      show(card);
      await wait(2300);
      save.classList.add('pressed');
      await wait(420);
      card.classList.add('gone');
      show(step('saved'));
      show(float('decision'));
      await wait(260);
      show(float('todo'));
      await wait(5200);
    };

    // Only while it's on screen and the tab is in front; a round that has started finishes.
    let onScreen = false;
    let resume = null;
    const check = () => {
      if (onScreen && !document.hidden && resume) {
        resume();
        resume = null;
      }
    };
    new IntersectionObserver((entries) => {
      onScreen = entries[entries.length - 1].isIntersecting;
      check();
    }, { threshold: 0.35 }).observe(demo);
    document.addEventListener('visibilitychange', check);
    (async () => {
      for (let round = 0; ; round++) {
        if (!onScreen || document.hidden) await new Promise((resolve) => { resume = resolve; });
        await play(round);
      }
    })();
  }
})();
