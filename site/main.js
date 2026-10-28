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

  // What starts below the fold fades in as it arrives, unless the reader prefers less motion.
  if (!('IntersectionObserver' in window) || window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
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
})();
