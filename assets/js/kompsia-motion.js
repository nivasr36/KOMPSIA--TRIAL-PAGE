/* KOMPSIA Premium Motion Layer */
(function installKompsiaMotion(global) {
  "use strict";

  const doc = global.document;
  if (!doc || !doc.documentElement) return;

  const reducedMotionQuery = global.matchMedia?.("(prefers-reduced-motion: reduce)");
  const coarsePointerQuery = global.matchMedia?.("(pointer: coarse)");
  const state = {
    observer: null,
    mutationObserver: null,
    raf: 0,
    reducedMotion: Boolean(reducedMotionQuery?.matches),
    coarsePointer: Boolean(coarsePointerQuery?.matches),
  };

  function injectStyles() {
    if (doc.getElementById("kompsia-motion-styles")) return;
    const style = doc.createElement("style");
    style.id = "kompsia-motion-styles";
    style.textContent = `
      :root{
        --km-ease:cubic-bezier(.16,1,.3,1);
        --km-fast:420ms;
        --km-slow:820ms;
      }

      html.km-reduced-motion *,
      html.km-reduced-motion *::before,
      html.km-reduced-motion *::after{
        scroll-behavior:auto!important;
        animation-duration:1ms!important;
        animation-iteration-count:1!important;
        transition-duration:1ms!important;
      }

      body::after{
        content:"";
        position:fixed;
        inset:-18vmax;
        z-index:0;
        pointer-events:none;
        opacity:.16;
        background:
          radial-gradient(circle at 24% 30%, rgba(91,123,209,.34), transparent 26%),
          radial-gradient(circle at 74% 68%, rgba(255,138,61,.26), transparent 24%);
        filter:blur(42px);
        transform:translate3d(0,0,0) rotate(0deg);
        animation:kmAmbientDrift 24s ease-in-out infinite alternate;
      }
      html.light body::after{ opacity:.10; }

      @keyframes kmAmbientDrift{
        0%{ transform:translate3d(-1.5%, -1%, 0) rotate(-2deg) scale(1); }
        100%{ transform:translate3d(1.5%, 1.5%, 0) rotate(2deg) scale(1.04); }
      }

      .km-reveal{
        opacity:0;
        transform:translate3d(0,26px,0) scale(.985);
        filter:blur(4px);
        transition:
          opacity var(--km-slow) var(--km-ease),
          transform var(--km-slow) var(--km-ease),
          filter var(--km-slow) var(--km-ease);
        transition-delay:var(--km-delay,0ms);
        will-change:opacity,transform,filter;
      }
      .km-reveal.km-visible{
        opacity:1;
        transform:translate3d(0,0,0) scale(1);
        filter:blur(0);
      }

      .km-reveal-left{ transform:translate3d(-32px,0,0); }
      .km-reveal-right{ transform:translate3d(32px,0,0); }
      .km-reveal-left.km-visible,
      .km-reveal-right.km-visible{ transform:translate3d(0,0,0); }

      .km-tilt{
        --km-rx:0deg;
        --km-ry:0deg;
        --km-mx:50%;
        --km-my:50%;
        transform-style:preserve-3d;
        will-change:transform;
      }
      .km-tilt::after{
        content:"";
        position:absolute;
        inset:0;
        z-index:2;
        pointer-events:none;
        opacity:0;
        background:radial-gradient(
          circle at var(--km-mx) var(--km-my),
          rgba(255,255,255,.18),
          rgba(255,255,255,.06) 24%,
          transparent 56%
        );
        transition:opacity .32s ease;
      }
      .km-tilt:hover::after{ opacity:.65; }
      .km-tilt.card-hov:hover{
        transform:
          perspective(900px)
          rotateX(var(--km-rx))
          rotateY(var(--km-ry))
          translate3d(0,-7px,0);
      }

      .km-image-wrap{ overflow:hidden; }
      .km-image-wrap img{
        transition:transform 1s var(--km-ease), filter .7s ease;
        will-change:transform;
      }
      .km-image-wrap:hover img{
        transform:scale(1.045);
        filter:saturate(1.04) contrast(1.02);
      }

      .km-button{
        position:relative;
        isolation:isolate;
        overflow:hidden;
      }
      .km-button::after{
        content:"";
        position:absolute;
        inset:-180% -70%;
        z-index:-1;
        pointer-events:none;
        background:linear-gradient(
          115deg,
          transparent 42%,
          rgba(255,255,255,.24) 49%,
          transparent 56%
        );
        transform:translateX(-42%) rotate(8deg);
        transition:transform .85s var(--km-ease);
      }
      .km-button:hover::after{ transform:translateX(42%) rotate(8deg); }

      nav.navbar{
        transition:
          background-color .35s ease,
          border-color .35s ease,
          color .35s ease,
          box-shadow .35s ease,
          transform .35s var(--km-ease)!important;
      }
      nav.navbar.km-nav-scrolled{
        box-shadow:0 16px 48px rgba(0,0,0,.24), inset 0 -1px 0 var(--glass-border);
      }

      .km-parallax{
        transform:translate3d(0,var(--km-parallax-y,0px),0) scale(1.025);
        will-change:transform;
      }

      .km-hero-heading{ animation:kmHeroIn 900ms var(--km-ease) both; }
      @keyframes kmHeroIn{
        from{ opacity:0; transform:translate3d(0,28px,0); letter-spacing:.04em; }
        to{ opacity:1; transform:translate3d(0,0,0); letter-spacing:normal; }
      }

      .km-float{
        animation:kmFloat 6s ease-in-out infinite;
        animation-delay:var(--km-float-delay,0s);
      }
      @keyframes kmFloat{
        0%,100%{ transform:translate3d(0,0,0); }
        50%{ transform:translate3d(0,-5px,0); }
      }

      @media (max-width: 760px), (pointer: coarse){
        .km-tilt.card-hov:hover{ transform:translate3d(0,-4px,0); }
        .km-tilt::after{ display:none; }
        .km-parallax{ transform:none!important; }
        body::after{ filter:blur(52px); opacity:.10; }
      }
    `;
    doc.head.appendChild(style);
  }

  function ensureIntersectionObserver() {
    if (state.reducedMotion || state.observer || !("IntersectionObserver" in global)) return;
    state.observer = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        entry.target.classList.add("km-visible");
        state.observer.unobserve(entry.target);
      });
    }, { threshold: 0.12, rootMargin: "0px 0px -6% 0px" });
  }

  function markReveal(element, index, variant) {
    if (!element || element.dataset.kmReveal === "1") return;
    element.dataset.kmReveal = "1";
    element.classList.add("km-reveal");
    if (variant) element.classList.add(variant);
    element.style.setProperty("--km-delay", `${Math.min(index * 55, 330)}ms`);
    if (state.reducedMotion || !state.observer) element.classList.add("km-visible");
    else state.observer.observe(element);
  }

  function attachTilt(card) {
    if (!card || card.dataset.kmTilt === "1") return;
    card.dataset.kmTilt = "1";
    card.classList.add("km-tilt");
    if (state.reducedMotion || state.coarsePointer) return;

    card.addEventListener("pointermove", (event) => {
      const rect = card.getBoundingClientRect();
      if (!rect.width || !rect.height) return;
      const x = (event.clientX - rect.left) / rect.width;
      const y = (event.clientY - rect.top) / rect.height;
      card.style.setProperty("--km-rx", `${((0.5 - y) * 6).toFixed(2)}deg`);
      card.style.setProperty("--km-ry", `${((x - 0.5) * 7).toFixed(2)}deg`);
      card.style.setProperty("--km-mx", `${(x * 100).toFixed(1)}%`);
      card.style.setProperty("--km-my", `${(y * 100).toFixed(1)}%`);
    }, { passive: true });

    card.addEventListener("pointerleave", () => {
      card.style.setProperty("--km-rx", "0deg");
      card.style.setProperty("--km-ry", "0deg");
      card.style.setProperty("--km-mx", "50%");
      card.style.setProperty("--km-my", "50%");
    }, { passive: true });
  }

  function enhance(root) {
    ensureIntersectionObserver();

    [...root.querySelectorAll("main section, main > div > div, main > section")]
      .filter((el) => !el.closest("[role='dialog']") && !el.classList.contains("drawer"))
      .slice(0, 40)
      .forEach((section, index) => markReveal(section, index % 6));

    [...root.querySelectorAll(".card-hov, .card")]
      .slice(0, 80)
      .forEach((card, index) => {
        markReveal(card, index % 6);
        if (card.classList.contains("card-hov")) attachTilt(card);
        if (card.querySelector("img")) card.classList.add("km-image-wrap");
      });

    [...root.querySelectorAll("main h2, main h3")]
      .slice(0, 40)
      .forEach((heading, index) => {
        markReveal(heading, index % 4, index % 2 ? "km-reveal-right" : "km-reveal-left");
      });

    root.querySelectorAll(".img-hover-wrap").forEach((el) => el.classList.add("km-image-wrap"));

    root.querySelectorAll(".btn, .btn-ghost").forEach((button, index) => {
      button.classList.add("km-button");
      if (index < 4 && !state.reducedMotion) {
        button.classList.add("km-float");
        button.style.setProperty("--km-float-delay", `${(index * 0.35).toFixed(2)}s`);
      }
    });

    const heading = root.querySelector("h1");
    if (heading && !heading.dataset.kmHero) {
      heading.dataset.kmHero = "1";
      heading.classList.add("km-hero-heading");
    }

    root.querySelectorAll(".hero-right, .about-hero-right").forEach((el) => el.classList.add("km-parallax"));
  }

  function updateParallax() {
    state.raf = 0;
    if (state.reducedMotion || state.coarsePointer) return;
    const viewport = global.innerHeight || 800;

    doc.querySelectorAll(".km-parallax").forEach((element) => {
      const rect = element.getBoundingClientRect();
      if (rect.bottom < -100 || rect.top > viewport + 100) return;
      const center = rect.top + rect.height / 2;
      const delta = (center - viewport / 2) / viewport;
      const y = Math.max(-14, Math.min(14, delta * -22));
      element.style.setProperty("--km-parallax-y", `${y.toFixed(2)}px`);
    });

    const nav = doc.querySelector("nav.navbar");
    if (nav) nav.classList.toggle("km-nav-scrolled", global.scrollY > 16);
  }

  function onScroll() {
    if (state.raf) return;
    state.raf = global.requestAnimationFrame(updateParallax);
  }

  function observeApp() {
    const app = doc.getElementById("app");
    if (!app || state.mutationObserver) return;
    state.mutationObserver = new MutationObserver((mutations) => {
      if (!mutations.some((m) => m.addedNodes.length)) return;
      global.requestAnimationFrame(() => {
        enhance(app);
        updateParallax();
      });
    });
    state.mutationObserver.observe(app, { childList: true, subtree: true });
  }

  function setMotionPreference() {
    state.reducedMotion = Boolean(reducedMotionQuery?.matches);
    doc.documentElement.classList.toggle("km-reduced-motion", state.reducedMotion);
    if (state.reducedMotion) doc.querySelectorAll(".km-reveal").forEach((el) => el.classList.add("km-visible"));
    else ensureIntersectionObserver();
  }

  function start() {
    injectStyles();
    setMotionPreference();
    enhance(doc);
    observeApp();
    updateParallax();
    global.addEventListener("scroll", onScroll, { passive: true });
    global.addEventListener("resize", onScroll, { passive: true });
  }

  reducedMotionQuery?.addEventListener?.("change", setMotionPreference);
  coarsePointerQuery?.addEventListener?.("change", (event) => { state.coarsePointer = Boolean(event.matches); });

  if (doc.readyState === "loading") doc.addEventListener("DOMContentLoaded", start, { once: true });
  else start();

  global.KompsiaMotion = Object.freeze({ refresh: () => enhance(doc) });
})(window);