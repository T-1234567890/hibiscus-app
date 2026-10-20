(() => {
  const config = window.HIBISCUS_SITE_CONFIG || {};

  document.querySelectorAll("[data-download-link]").forEach((link) => {
    const label = link.querySelector("[data-download-label]");
    const hoverLabel = link.querySelector("[data-download-hover-label]");
    if (label && config.downloadLabel) label.textContent = config.downloadLabel;
    if (hoverLabel && config.downloadHoverLabel) hoverLabel.textContent = config.downloadHoverLabel;

    if (config.downloadURL) {
      link.href = config.downloadURL;
      link.removeAttribute("aria-disabled");
      link.removeAttribute("data-unavailable");
    } else {
      link.removeAttribute("href");
      link.setAttribute("data-unavailable", "true");
      link.setAttribute("aria-disabled", "true");
      link.setAttribute("aria-label", `${config.downloadLabel || "Download"}. Coming soon.`);
      link.addEventListener("click", (event) => event.preventDefault());
    }
  });

  const prefersReducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  const revealTargets = document.querySelectorAll(
    ".swift-native-section, .dictionary-entry, .conveyor-caption, .marquee, .screenshots-section .carousel, .carousel-dots, .legal-document"
  );

  if (!prefersReducedMotion.matches && "IntersectionObserver" in window) {
    revealTargets.forEach((target, index) => {
      target.classList.add("reveal-item");
      target.style.setProperty("--reveal-delay", `${(index % 3) * 70}ms`);
    });

    const revealObserver = new IntersectionObserver((entries) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        entry.target.classList.add("is-revealed");
        revealObserver.unobserve(entry.target);
      });
    }, { threshold: 0.12, rootMargin: "0px 0px -7%" });

    revealTargets.forEach((target) => revealObserver.observe(target));
  }

  document.querySelectorAll(".marquee").forEach((marquee) => {
    const track = marquee.querySelector(".marquee-track");
    if (!track || typeof track.getAnimations !== "function") return;

    const setPlaybackRate = (rate) => {
      track.getAnimations().forEach((animation) => {
        if (typeof animation.updatePlaybackRate === "function") animation.updatePlaybackRate(rate);
        else animation.playbackRate = rate;
      });
    };

    const syncPlaybackRate = () => {
      const isInteracting = marquee.matches(":hover") || marquee.contains(document.activeElement);
      setPlaybackRate(isInteracting ? 0.28 : 1);
    };

    marquee.addEventListener("pointerenter", syncPlaybackRate);
    marquee.addEventListener("pointerleave", syncPlaybackRate);
    marquee.addEventListener("focusin", syncPlaybackRate);
    marquee.addEventListener("focusout", () => window.requestAnimationFrame(syncPlaybackRate));
  });

  const carousel = document.querySelector("[data-carousel]");
  if (!carousel) return;

  const cards = [...carousel.querySelectorAll(".screenshot-card")];
  const dotsContainer = document.querySelector("[data-carousel-dots]");
  if (!cards.length || !dotsContainer) return;

  let currentIndex = 0;
  let trackIndex = cards.length;
  let autoplayTimer = null;
  let resumeTimer = null;
  let scrollSettleTimer = null;
  let scrollFrame = null;
  let carouselVisible = false;
  let activePointerId = null;
  let dragState = null;

  cards.forEach((card, index) => { card.dataset.logicalIndex = String(index); });

  const cloneCard = (card) => {
    const clone = card.cloneNode(true);
    clone.classList.add("is-clone");
    clone.classList.remove("is-current");
    clone.setAttribute("aria-hidden", "true");
    clone.querySelector("img")?.setAttribute("alt", "");
    return clone;
  };

  const leadingCards = cards.map(cloneCard);
  const trailingCards = cards.map(cloneCard);
  carousel.prepend(...leadingCards);
  carousel.append(...trailingCards);

  const trackCards = [...carousel.querySelectorAll(".screenshot-card")];
  const dots = cards.map((_, index) => {
    const dot = document.createElement("button");
    dot.type = "button";
    dot.className = "carousel-dot";
    dot.setAttribute("aria-label", `Show screenshot ${index + 1} of ${cards.length}`);
    dotsContainer?.append(dot);
    return dot;
  });

  const setCurrent = (logicalIndex, activeTrackIndex = cards.length + logicalIndex) => {
    currentIndex = (logicalIndex + cards.length) % cards.length;
    trackIndex = activeTrackIndex;
    trackCards.forEach((card, index) => card.classList.toggle("is-current", index === activeTrackIndex));
    dots.forEach((dot, index) => {
      const selected = index === currentIndex;
      dot.classList.toggle("is-current", selected);
      if (selected) dot.setAttribute("aria-current", "true");
      else dot.removeAttribute("aria-current");
    });
  };

  const scrollToTrackCard = (index, behavior = prefersReducedMotion.matches ? "auto" : "smooth") => {
    const target = trackCards[Math.max(0, Math.min(trackCards.length - 1, index))];
    if (!target) return;
    carousel.scrollTo({
      left: target.offsetLeft - ((carousel.clientWidth - target.clientWidth) / 2),
      behavior
    });
  };

  const closestTrackIndex = () => {
    const center = carousel.scrollLeft + (carousel.clientWidth / 2);
    return trackCards.reduce((closest, card, index) => {
      const cardCenter = card.offsetLeft + (card.clientWidth / 2);
      const distance = Math.abs(cardCenter - center);
      return distance < closest.distance ? { index, distance } : closest;
    }, { index: 1, distance: Number.POSITIVE_INFINITY }).index;
  };

  const normalizeLoop = () => {
    if (activePointerId !== null) return;

    const closest = closestTrackIndex();
    const logicalIndex = Number(trackCards[closest].dataset.logicalIndex);
    let normalizedIndex = closest;

    if (closest < cards.length) normalizedIndex = closest + cards.length;
    if (closest >= cards.length * 2) normalizedIndex = closest - cards.length;

    if (normalizedIndex !== closest) {
      carousel.classList.add("is-normalizing");
      scrollToTrackCard(normalizedIndex, "auto");
      setCurrent(logicalIndex, normalizedIndex);
      window.requestAnimationFrame(() => carousel.classList.remove("is-normalizing"));
      return;
    }

    setCurrent(logicalIndex, normalizedIndex);
  };

  carousel.addEventListener("scroll", () => {
    window.clearTimeout(scrollSettleTimer);
    if (!scrollFrame) {
      scrollFrame = window.requestAnimationFrame(() => {
        const closest = closestTrackIndex();
        setCurrent(Number(trackCards[closest].dataset.logicalIndex), closest);
        scrollFrame = null;
      });
    }
    scrollSettleTimer = window.setTimeout(normalizeLoop, 140);
  }, { passive: true });

  const pauseAutoplay = () => {
    window.clearInterval(autoplayTimer);
    autoplayTimer = null;
  };

  const advanceCarousel = () => {
    const middleIndex = cards.length + currentIndex;
    if (trackIndex !== middleIndex) {
      setCurrent(currentIndex, middleIndex);
      scrollToTrackCard(middleIndex, "auto");
    }
    window.requestAnimationFrame(() => scrollToTrackCard(middleIndex + 1));
  };

  const startAutoplay = (advanceImmediately = false) => {
    pauseAutoplay();
    window.clearTimeout(resumeTimer);
    resumeTimer = null;
    if (prefersReducedMotion.matches || !carouselVisible || document.hidden) return;
    if (advanceImmediately) advanceCarousel();
    autoplayTimer = window.setInterval(advanceCarousel, 3800);
  };

  const resumeAutoplaySoon = (delay = 2400) => {
    pauseAutoplay();
    window.clearTimeout(resumeTimer);
    resumeTimer = window.setTimeout(() => startAutoplay(true), delay);
  };

  dots.forEach((dot, index) => {
    dot.addEventListener("click", () => {
      pauseAutoplay();
      scrollToTrackCard(cards.length + index);
      resumeAutoplaySoon();
    });
  });

  const moveCarouselBy = (distance) => {
    const middleIndex = cards.length + currentIndex;
    if (trackIndex !== middleIndex) {
      setCurrent(currentIndex, middleIndex);
      scrollToTrackCard(middleIndex, "auto");
    }
    window.requestAnimationFrame(() => scrollToTrackCard(middleIndex + distance));
  };

  carousel.addEventListener("keydown", (event) => {
    if (event.key === "ArrowLeft") {
      event.preventDefault();
      pauseAutoplay();
      moveCarouselBy(-1);
      resumeAutoplaySoon();
    }
    if (event.key === "ArrowRight") {
      event.preventDefault();
      pauseAutoplay();
      moveCarouselBy(1);
      resumeAutoplaySoon();
    }
  });
  const finishPointerInteraction = (event) => {
    if (activePointerId === null || event.pointerId !== activePointerId) return;

    if (dragState) {
      if (carousel.hasPointerCapture?.(event.pointerId)) {
        carousel.releasePointerCapture(event.pointerId);
      }
      dragState = null;
      carousel.classList.remove("is-dragging");
    }

    activePointerId = null;
    window.removeEventListener("pointerup", finishPointerInteraction);
    window.removeEventListener("pointercancel", finishPointerInteraction);
    scrollToTrackCard(closestTrackIndex());
    resumeAutoplaySoon();
  };

  carousel.addEventListener("pointerdown", (event) => {
    if (activePointerId !== null || (event.pointerType === "mouse" && event.button !== 0)) return;

    pauseAutoplay();
    window.clearTimeout(resumeTimer);
    activePointerId = event.pointerId;

    if (event.pointerType === "mouse") {
      dragState = {
        startX: event.clientX,
        startScrollLeft: carousel.scrollLeft
      };
      carousel.classList.add("is-dragging");
      carousel.setPointerCapture?.(event.pointerId);
    }

    window.addEventListener("pointerup", finishPointerInteraction);
    window.addEventListener("pointercancel", finishPointerInteraction);
  });

  carousel.addEventListener("pointermove", (event) => {
    if (!dragState || event.pointerId !== activePointerId) return;
    event.preventDefault();
    carousel.scrollLeft = dragState.startScrollLeft - (event.clientX - dragState.startX);
  });
  carousel.addEventListener("wheel", () => resumeAutoplaySoon(), { passive: true });

  const visibilityObserver = new IntersectionObserver(([entry]) => {
    carouselVisible = entry.isIntersecting && entry.intersectionRatio >= 0.45;
    if (carouselVisible) startAutoplay();
    else pauseAutoplay();
  }, { threshold: [0, 0.45] });

  visibilityObserver.observe(carousel);
  document.addEventListener("visibilitychange", () => startAutoplay());
  prefersReducedMotion.addEventListener("change", () => startAutoplay());
  window.addEventListener("resize", () => scrollToTrackCard(cards.length + currentIndex, "auto"));
  setCurrent(0, cards.length);
  window.requestAnimationFrame(() => scrollToTrackCard(cards.length, "auto"));
})();
