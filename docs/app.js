/* ==========================================================================
   Etonia Official Website — Interactive Behavior & Waitlist Integration
   ========================================================================== */

(function () {
  'use strict';

  const SUPABASE_URL = 'https://ualdmkijvjgdzraontdg.supabase.co';
  const SUPABASE_ANON_KEY =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVhbGRta2lqdmpnZHpyYW9udGRnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTIyOTQ2MTAsImV4cCI6MjEwNzg3MDYxMH0.QUZ_tfHd6gwSQMsozcCICPPmVmPW-ePwjBhIRsyz1Eg';

  const SHOWCASE_SCREENS = {
    ai: {
      light: 'assets/screenshots/hero_ai_light.png',
      dark: 'assets/screenshots/hero_ai_dark.png',
      alt: 'Etonia editor showing handwritten quadratic equations on lined paper, a lasso selection, an AI-drawn parabola with roots and vertex marked in handwriting, and the AI assistant panel on the right.',
      caption:
        '<strong>AI Assistant &amp; Handwritten Notation:</strong> Lasso any equation or diagram, tap <strong>Explain this</strong> or <strong>Grade this</strong>, and watch Etonia plot curves and write step-by-step marks directly on your vector page.'
    },
    ink: {
      light: 'assets/screenshots/feature_ink_studio_light.png',
      dark: 'assets/screenshots/feature_ink_studio_light.png',
      alt: 'Etonia editor on dotted paper showing wave optics formulas, a hold-to-shape sine wave and circle, a yellow lined sticky note with handwritten exam reminders, and the pen options bar.',
      caption:
        '<strong>Native Low-Latency Ink, Hold-to-Shape &amp; Sticky Notes:</strong> Full-rate Apple Pencil and S Pen/USI sampling with One Euro smoothing, instant shape snapping, and movable handwritten sticky notes.'
    },
    handwriting: {
      light: 'assets/screenshots/feature_handwriting_styles.png',
      dark: 'assets/screenshots/feature_handwriting_styles.png',
      alt: 'Etonia handwriting style picker showing Normal, Cursive, Print, Rounded, Quick, and Your handwriting calibration option.',
      caption:
        '<strong>Writes in Your Handwriting:</strong> Pick from five built-in hands (Normal, Cursive, Print, Rounded, Quick) or write 15 letters once so the AI writes on your notes in your own hand.'
    },
    library: {
      light: 'assets/screenshots/feature_library_light.png',
      dark: 'assets/screenshots/feature_library_dark.png',
      alt: 'Etonia library view with folder sidebar, Lectures folder, dog-eared note card thumbnail, search bar, and New note button.',
      caption:
        '<strong>Library, Folders &amp; Cloud Backup:</strong> Organize notes in nested folders with dog-eared first-page thumbnails, automatic Google Drive &amp; iCloud backup, and direct Goodnotes import.'
    },
    overview: {
      light: 'assets/screenshots/feature_tabs_overview_light.png',
      dark: 'assets/screenshots/feature_tabs_overview_light.png',
      alt: 'Etonia editor with the Pages overview popover open on the left showing miniature previews of Page 1 and Page 2.',
      caption:
        '<strong>Multi-Page Overview &amp; Vector Export:</strong> Mix A4, Letter, Square, and Infinite Whiteboard pages in one notebook, and export lossless PDF or SVG vectors.'
    }
  };

  let currentTheme = 'light';
  let currentShowcaseKey = 'ai';
  let paperOverride = null; // null follows site theme, or 'light' | 'dark'
  let selectedPlatform = 'ipad';

  /* ------------------------------------------------------------------------
     1. Theme Management (Light / Dark)
     ------------------------------------------------------------------------ */
  function initTheme() {
    const saved = localStorage.getItem('etonia_theme');
    if (saved === 'dark' || saved === 'light') {
      currentTheme = saved;
    } else if (
      window.matchMedia &&
      window.matchMedia('(prefers-color-scheme: dark)').matches
    ) {
      currentTheme = 'dark';
    }
    applyTheme(currentTheme, false);
  }

  function applyTheme(theme, persist) {
    currentTheme = theme;
    document.documentElement.setAttribute('data-theme', theme);
    if (persist) {
      localStorage.setItem('etonia_theme', theme);
    }
    const toggleBtn = document.getElementById('theme-toggle');
    if (toggleBtn) {
      const isDark = theme === 'dark';
      toggleBtn.setAttribute(
        'aria-label',
        isDark ? 'Switch to light paper theme' : 'Switch to dark ink theme'
      );
      toggleBtn.setAttribute('title', isDark ? 'Light mode' : 'Dark mode');
      const sunIcon = toggleBtn.querySelector('.icon-sun');
      const moonIcon = toggleBtn.querySelector('.icon-moon');
      if (sunIcon && moonIcon) {
        sunIcon.style.display = isDark ? 'block' : 'none';
        moonIcon.style.display = isDark ? 'none' : 'block';
      }
    }

    // Update theme-sensitive images across the page
    document.querySelectorAll('img[data-src-light][data-src-dark]').forEach((img) => {
      img.src =
        theme === 'dark'
          ? img.getAttribute('data-src-dark')
          : img.getAttribute('data-src-light');
    });

    updateShowcaseImage();
  }

  /* ------------------------------------------------------------------------
     2. Hero Showcase Switcher
     ------------------------------------------------------------------------ */
  function updateShowcaseImage() {
    const entry = SHOWCASE_SCREENS[currentShowcaseKey] || SHOWCASE_SCREENS.ai;
    const effectiveMode = paperOverride || currentTheme;
    const imgEl = document.getElementById('showcase-main-img');
    const captionEl = document.getElementById('showcase-caption');

    if (imgEl) {
      const nextSrc = effectiveMode === 'dark' ? entry.dark : entry.light;
      if (imgEl.getAttribute('src') !== nextSrc) {
        imgEl.setAttribute('src', nextSrc);
      }
      imgEl.setAttribute('alt', entry.alt);
    }
    if (captionEl) {
      captionEl.innerHTML = entry.caption;
    }

    // Update paper mode toggle buttons
    document.querySelectorAll('[data-paper-mode]').forEach((btn) => {
      const mode = btn.getAttribute('data-paper-mode');
      btn.classList.toggle('is-active', mode === effectiveMode);
    });
  }

  function initShowcase() {
    document.querySelectorAll('[data-showcase-tab]').forEach((btn) => {
      btn.addEventListener('click', () => {
        currentShowcaseKey = btn.getAttribute('data-showcase-tab');
        document.querySelectorAll('[data-showcase-tab]').forEach((b) => {
          const active = b === btn;
          b.classList.toggle('is-active', active);
          b.setAttribute('aria-selected', active ? 'true' : 'false');
        });
        updateShowcaseImage();
      });
    });

    document.querySelectorAll('[data-paper-mode]').forEach((btn) => {
      btn.addEventListener('click', () => {
        paperOverride = btn.getAttribute('data-paper-mode');
        updateShowcaseImage();
      });
    });
  }

  /* ------------------------------------------------------------------------
     3. Waitlist Platform Selection & Submission
     ------------------------------------------------------------------------ */
  function setPlatform(platform) {
    selectedPlatform = platform;
    document.querySelectorAll('.platform-pill').forEach((pill) => {
      const match = pill.getAttribute('data-platform') === platform;
      pill.setAttribute('aria-pressed', match ? 'true' : 'false');
    });
  }

  async function submitWaitlist(email, platform, source) {
    const cleanEmail = (email || '').trim().toLowerCase();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(cleanEmail)) {
      throw new Error('Please enter a valid email address.');
    }

    // Save locally immediately so the user's spot is remembered on this browser
    const localRecord = {
      email: cleanEmail,
      platform: platform,
      source: source,
      joinedAt: new Date().toISOString()
    };
    try {
      localStorage.setItem('etonia_waitlist_entry', JSON.stringify(localRecord));
    } catch (_) {
      // Ignore storage quota errors in private browsing
    }

    // Attempt Supabase RPC submission (public.join_waitlist)
    try {
      const response = await fetch(`${SUPABASE_URL}/rest/v1/rpc/join_waitlist`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          apikey: SUPABASE_ANON_KEY,
          Authorization: `Bearer ${SUPABASE_ANON_KEY}`
        },
        body: JSON.stringify({
          p_email: cleanEmail,
          p_platform: platform,
          p_source: source
        })
      });

      if (response.ok) {
        return { synced: true, email: cleanEmail, platform: platform };
      }
    } catch (_) {
      // Network or CORS fallback handled gracefully below
    }

    return { synced: false, email: cleanEmail, platform: platform };
  }

  function initWaitlistForms() {
    document.querySelectorAll('.platform-pill').forEach((pill) => {
      pill.addEventListener('click', () => {
        setPlatform(pill.getAttribute('data-platform') || 'ipad');
      });
    });

    document.querySelectorAll('.waitlist-form').forEach((form) => {
      form.addEventListener('submit', async (event) => {
        event.preventDefault();
        const emailInput = form.querySelector('input[type="email"]');
        const submitBtn = form.querySelector('button[type="submit"]');
        const statusEl = form.querySelector('.waitlist-status');
        const source = form.getAttribute('data-source') || 'github_website';

        if (!emailInput || !submitBtn || !statusEl) return;

        const originalLabel = submitBtn.textContent;
        submitBtn.disabled = true;
        submitBtn.textContent = 'Joining…';
        statusEl.className = 'waitlist-status';

        try {
          const result = await submitWaitlist(
            emailInput.value,
            selectedPlatform,
            source
          );
          const platformNames = {
            ipad: 'iPad',
            android: 'Android Tablet',
            iphone: 'iPhone',
            all: 'iPad, iPhone & Android'
          };
          const platLabel = platformNames[result.platform] || 'iPad';
          statusEl.className = 'waitlist-status is-visible is-success';
          statusEl.innerHTML =
            `<span>✓ You're on the Etonia waitlist for <strong>${platLabel}</strong> (${result.email}). Follow <a href="https://www.instagram.com/etoniaaa/" target="_blank" rel="noopener noreferrer" style="text-decoration:underline;">@etoniaaa on Instagram</a> for early TestFlight &amp; beta drops.</span>`;
          emailInput.value = '';
        } catch (err) {
          statusEl.className = 'waitlist-status is-visible is-error';
          statusEl.textContent =
            err && err.message
              ? err.message
              : 'Could not join right now. Please check your email and try again.';
        } finally {
          submitBtn.disabled = false;
          submitBtn.textContent = originalLabel;
        }
      });
    });

    // If user already joined previously, show a subtle note
    try {
      const existing = localStorage.getItem('etonia_waitlist_entry');
      if (existing) {
        const parsed = JSON.parse(existing);
        if (parsed && parsed.email) {
          setPlatform(parsed.platform || 'ipad');
        }
      }
    } catch (_) {}
  }

  /* ------------------------------------------------------------------------
     4. Full-Resolution Screenshot Lightbox
     ------------------------------------------------------------------------ */
  function initLightbox() {
    const lightbox = document.getElementById('screenshot-lightbox');
    const lightboxImg = document.getElementById('lightbox-img');
    const closeBtn = document.getElementById('lightbox-close');

    if (!lightbox || !lightboxImg) return;

    function openLightbox(src, alt) {
      lightboxImg.setAttribute('src', src);
      lightboxImg.setAttribute('alt', alt || 'Etonia screenshot');
      lightbox.classList.add('is-open');
      lightbox.setAttribute('aria-hidden', 'false');
    }

    function closeLightbox() {
      lightbox.classList.remove('is-open');
      lightbox.setAttribute('aria-hidden', 'true');
    }

    document.querySelectorAll('.zoomable-shot').forEach((container) => {
      container.addEventListener('click', () => {
        const img =
          container.tagName === 'IMG'
            ? container
            : container.querySelector('img');
        if (img) {
          openLightbox(img.getAttribute('src'), img.getAttribute('alt'));
        }
      });
    });

    if (closeBtn) {
      closeBtn.addEventListener('click', closeLightbox);
    }
    lightbox.addEventListener('click', (e) => {
      if (e.target === lightbox) closeLightbox();
    });
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape' && lightbox.classList.contains('is-open')) {
        closeLightbox();
      }
    });
  }

  /* ------------------------------------------------------------------------
     Boot
     ------------------------------------------------------------------------ */
  document.addEventListener('DOMContentLoaded', () => {
    initTheme();
    const themeBtn = document.getElementById('theme-toggle');
    if (themeBtn) {
      themeBtn.addEventListener('click', () => {
        paperOverride = null;
        applyTheme(currentTheme === 'dark' ? 'light' : 'dark', true);
      });
    }
    initShowcase();
    initWaitlistForms();
    initLightbox();
  });
})();
