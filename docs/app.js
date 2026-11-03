/* ==========================================================================
   Etonia Official Website — Waitlist & Screenshot Steppers
   ========================================================================== */

(function () {
  'use strict';

  const SUPABASE_URL = 'https://ualdmkijvjgdzraontdg.supabase.co';
  const SUPABASE_ANON_KEY =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVhbGRta2lqdmpnZHpyYW9udGRnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTIyOTQ2MTAsImV4cCI6MjEwNzg3MDYxMH0.QUZ_tfHd6gwSQMsozcCICPPmVmPW-ePwjBhIRsyz1Eg';

  /* ------------------------------------------------------------------------
     1. Streamlined Email-Only Waitlist
     ------------------------------------------------------------------------ */
  async function submitWaitlist(email, source) {
    const cleanEmail = (email || '').trim().toLowerCase();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(cleanEmail)) {
      throw new Error('Please enter a valid email address.');
    }

    try {
      localStorage.setItem(
        'etonia_waitlist_entry',
        JSON.stringify({
          email: cleanEmail,
          source: source,
          joinedAt: new Date().toISOString()
        })
      );
    } catch (_) {}

    try {
      await fetch(`${SUPABASE_URL}/rest/v1/rpc/join_waitlist`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          apikey: SUPABASE_ANON_KEY,
          Authorization: `Bearer ${SUPABASE_ANON_KEY}`
        },
        body: JSON.stringify({
          p_email: cleanEmail,
          p_platform: 'all',
          p_source: source
        })
      });
    } catch (_) {}

    return cleanEmail;
  }

  function initWaitlistForms() {
    document.querySelectorAll('.waitlist-form').forEach((form) => {
      form.addEventListener('submit', async (event) => {
        event.preventDefault();
        const emailInput = form.querySelector('input[type="email"]');
        const submitBtn = form.querySelector('button[type="submit"]');
        const statusEl = form.querySelector('.waitlist-status');
        const source = form.getAttribute('data-source') || 'github_website';

        if (!emailInput || !submitBtn || !statusEl) return;

        const originalText = submitBtn.textContent;
        submitBtn.disabled = true;
        submitBtn.textContent = 'Joining…';
        statusEl.className = 'waitlist-status';

        try {
          const savedEmail = await submitWaitlist(emailInput.value, source);
          statusEl.className = 'waitlist-status is-visible is-success';
          statusEl.innerHTML = `✓ You're on the waitlist (<strong>${savedEmail}</strong>). Follow <a href="https://www.instagram.com/etoniaaa/" target="_blank" rel="noopener noreferrer" style="text-decoration:underline;">@etoniaaa on Instagram</a> for updates.`;
          emailInput.value = '';
        } catch (err) {
          statusEl.className = 'waitlist-status is-visible is-error';
          statusEl.textContent =
            err && err.message ? err.message : 'Please enter a valid email.';
        } finally {
          submitBtn.disabled = false;
          submitBtn.textContent = originalText;
        }
      });
    });
  }

  /* ------------------------------------------------------------------------
     2. Steppers: buttons beside a screenshot that show its frames in turn,
        by themselves while on screen unless the reader prefers less motion.
     ------------------------------------------------------------------------ */
  function initStepper(root) {
    const stepButtons = Array.from(root.querySelectorAll('[data-step]'));
    const frames = Array.from(root.querySelectorAll('[data-frame]'));
    if (!stepButtons.length || !frames.length) return;

    const interval = Number(root.getAttribute('data-interval')) || 2800;
    const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
    let currentStep = 1;
    let timerId = null;
    let onScreen = false;
    let held = false;

    function setStep(step) {
      currentStep = step;
      stepButtons.forEach((btn) => {
        const match = Number(btn.getAttribute('data-step')) === step;
        btn.classList.toggle('is-active', match);
        btn.setAttribute('aria-pressed', match ? 'true' : 'false');
      });
      frames.forEach((frame) => {
        const match = Number(frame.getAttribute('data-frame')) === step;
        frame.classList.toggle('is-active', match);
      });
    }

    function stopAutoCycle() {
      if (timerId !== null) {
        window.clearInterval(timerId);
        timerId = null;
      }
    }

    function updateAutoCycle() {
      stopAutoCycle();
      if (!onScreen || held || reduceMotion.matches) return;
      timerId = window.setInterval(() => {
        setStep(currentStep >= stepButtons.length ? 1 : currentStep + 1);
      }, interval);
    }

    stepButtons.forEach((btn) => {
      const step = Number(btn.getAttribute('data-step')) || 1;
      btn.addEventListener('click', () => {
        setStep(step);
        updateAutoCycle();
      });
      btn.addEventListener('mouseenter', () => {
        held = true;
        setStep(step);
        updateAutoCycle();
      });
      btn.addEventListener('mouseleave', () => {
        held = false;
        updateAutoCycle();
      });
    });

    new IntersectionObserver(
      (entries) => {
        onScreen = entries[entries.length - 1].isIntersecting;
        updateAutoCycle();
      },
      { threshold: 0.4 }
    ).observe(root);
  }

  /* ------------------------------------------------------------------------
     3. Lightbox Modal for Screenshots
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
        const activeImg =
          container.querySelector('img.is-active') ||
          (container.tagName === 'IMG'
            ? container
            : container.querySelector('img'));
        if (activeImg) {
          openLightbox(
            activeImg.getAttribute('src'),
            activeImg.getAttribute('alt')
          );
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

  document.addEventListener('DOMContentLoaded', () => {
    initWaitlistForms();
    document.querySelectorAll('[data-stepper]').forEach(initStepper);
    initLightbox();
  });
})();
