// Pricing monthly/annual toggle. Runs only on pages that render the pricing section.
(function () {
  const mo = document.getElementById('mo');
  const yr = document.getElementById('yr');
  if (!mo || !yr) return;
  function set(annual) {
    mo.setAttribute('aria-pressed', String(!annual));
    yr.setAttribute('aria-pressed', String(annual));
    document.querySelectorAll('[data-m]').forEach((e) => {
      e.textContent = '$' + (annual ? e.dataset.y : e.dataset.m);
    });
    document.querySelectorAll('[data-b]').forEach((e) => {
      e.textContent = annual ? 'Billed annually at $' + (e.dataset.b * 12 * 0.8).toFixed(0) : 'Billed monthly';
    });
  }
  mo.addEventListener('click', () => set(false));
  yr.addEventListener('click', () => set(true));
  set(false);
})();
