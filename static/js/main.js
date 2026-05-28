// main.js — SkyRoute global scripts

document.addEventListener('DOMContentLoaded', () => {

  // ── Auto-dismiss flash messages after 5s ──────────────────
  document.querySelectorAll('.flash').forEach(el => {
    setTimeout(() => {
      el.style.transition = 'opacity 0.5s ease, transform 0.5s ease';
      el.style.opacity = '0';
      el.style.transform = 'translateY(-8px)';
      setTimeout(() => el.remove(), 500);
    }, 5000);
  });

  // ── Search tab toggle (One Way / Round Trip) ───────────────
  document.querySelectorAll('.tab').forEach(tab => {
    tab.addEventListener('click', () => {
      document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
      tab.classList.add('active');
    });
  });

  // ── Animate numbers in stats bar ──────────────────────────
  function animateCount(el, target, suffix='') {
    let start = 0;
    const step = Math.ceil(target / 40);
    const timer = setInterval(() => {
      start = Math.min(start + step, target);
      el.textContent = start + suffix;
      if (start >= target) clearInterval(timer);
    }, 30);
  }

  const observer = new IntersectionObserver(entries => {
    entries.forEach(e => {
      if (e.isIntersecting) {
        const el  = e.target;
        const raw = el.dataset.count;
        if (!raw) return;
        const num = parseInt(raw);
        const sfx = el.dataset.suffix || '';
        animateCount(el, num, sfx);
        observer.unobserve(el);
      }
    });
  }, { threshold: 0.5 });

  document.querySelectorAll('[data-count]').forEach(el => observer.observe(el));

  // ── Booking form: live price update on coupon clear ────────
  const couponInput = document.getElementById('couponInput');
  if (couponInput) {
    couponInput.addEventListener('input', () => {
      if (!couponInput.value.trim()) {
        const discRow = document.getElementById('discountRow');
        if (discRow) discRow.classList.add('hidden');
        const base = parseFloat(document.getElementById('ps-base')?.textContent?.replace('$','') || 0);
        const total = document.getElementById('ps-total');
        if (total && base) total.textContent = `$${base.toFixed(2)}`;
        const msg = document.getElementById('couponMsg');
        if (msg) msg.innerHTML = '';
      }
    });
    // Allow Enter key to apply coupon
    couponInput.addEventListener('keydown', e => {
      if (e.key === 'Enter') {
        e.preventDefault();
        if (typeof validateCoupon === 'function') validateCoupon();
      }
    });
  }

  // ── Confirm booking form before submit ─────────────────────
  const bookingForm = document.getElementById('bookingForm');
  if (bookingForm) {
    bookingForm.addEventListener('submit', e => {
      const total = document.getElementById('ps-total')?.textContent || '';
      const flight = document.querySelector('input[name=flight_id]')?.value;
      if (!confirm(`Confirm booking for ${total}?\n\nThis will charge your selected payment method.`)) {
        e.preventDefault();
      }
    });
  }

  // ── Seat picker visual (optional enhancement) ─────────────
  // Highlights selected seat row in booking form
  document.querySelectorAll('.payment-option').forEach(opt => {
    opt.addEventListener('click', () => {
      document.querySelectorAll('.payment-option').forEach(o => o.style.borderColor = '');
      opt.style.borderColor = 'var(--blue)';
    });
  });

  // ── Result card hover sound-effect (subtle) ───────────────
  // (Silent – placeholder for future audio integration)

  // ── Date input: set today as default if empty ─────────────
  const dateInput = document.querySelector('input[type="date"]');
  if (dateInput && !dateInput.value) {
    const today = new Date().toISOString().split('T')[0];
    dateInput.min = today;
  }

  // ── Search form: prevent same origin = destination ─────────
  const searchForm = document.getElementById('searchForm');
  if (searchForm) {
    searchForm.addEventListener('submit', e => {
      const selects = searchForm.querySelectorAll('select');
      const origin = selects[0]?.value;
      const dest   = selects[1]?.value;
      if (origin && dest && origin === dest) {
        e.preventDefault();
        showToast('Origin and destination cannot be the same.', 'error');
      }
    });
  }

  // ── Toast notification helper ──────────────────────────────
  window.showToast = function(msg, type='success') {
    const toast = document.createElement('div');
    toast.className = `flash flash-${type}`;
    toast.style.cssText = `
      position:fixed; bottom:24px; right:24px; z-index:999;
      max-width:360px; animation:slideIn 0.3s ease;
    `;
    toast.innerHTML = `<span>${type === 'success' ? '✓' : '✗'}</span> ${msg}`;
    document.body.appendChild(toast);
    setTimeout(() => {
      toast.style.opacity = '0';
      setTimeout(() => toast.remove(), 400);
    }, 4000);
  };

  // ── Smooth scroll for anchor links ────────────────────────
  document.querySelectorAll('a[href^="#"]').forEach(a => {
    a.addEventListener('click', e => {
      const target = document.querySelector(a.getAttribute('href'));
      if (target) { e.preventDefault(); target.scrollIntoView({ behavior: 'smooth' }); }
    });
  });

  // ── Flight card entrance animation ────────────────────────
  const cardObserver = new IntersectionObserver(entries => {
    entries.forEach((e, i) => {
      if (e.isIntersecting) {
        e.target.style.animationDelay = `${i * 0.05}s`;
        e.target.classList.add('card-visible');
        cardObserver.unobserve(e.target);
      }
    });
  }, { threshold: 0.1 });

  document.querySelectorAll('.result-card, .booking-item, .deal-card').forEach(card => {
    card.style.opacity = '0';
    card.style.transform = 'translateY(16px)';
    card.style.transition = 'opacity 0.4s ease, transform 0.4s ease';
    cardObserver.observe(card);
  });

  // Inject CSS for card-visible class dynamically
  const style = document.createElement('style');
  style.textContent = `.card-visible { opacity: 1 !important; transform: translateY(0) !important; }`;
  document.head.appendChild(style);

});
