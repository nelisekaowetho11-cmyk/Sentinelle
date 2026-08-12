// ── Theme ────────────────────────────────────────────────────────────────────
(function () {
  const saved = localStorage.getItem('theme') || 'dark';
  document.documentElement.setAttribute('data-theme', saved);
})();

document.addEventListener('DOMContentLoaded', function () {
  feather.replace();

  // Theme toggle
  const btn     = document.getElementById('theme-toggle');
  const sunIcon = document.getElementById('icon-sun');
  const moonIcon = document.getElementById('icon-moon');

  function applyTheme(theme) {
    document.documentElement.setAttribute('data-theme', theme);
    localStorage.setItem('theme', theme);
    if (sunIcon && moonIcon) {
      sunIcon.style.display  = theme === 'dark'  ? '' : 'none';
      moonIcon.style.display = theme === 'light' ? '' : 'none';
    }
    feather.replace();
  }

  // Init icons
  const current = localStorage.getItem('theme') || 'dark';
  applyTheme(current);

  if (btn) {
    btn.addEventListener('click', function () {
      const cur  = document.documentElement.getAttribute('data-theme');
      applyTheme(cur === 'dark' ? 'light' : 'dark');
    });
  }

  // Sidebar toggle (mobile)
  const sidebarToggle = document.getElementById('sidebar-toggle');
  const sidebar       = document.getElementById('sidebar');
  if (sidebarToggle && sidebar) {
    sidebarToggle.addEventListener('click', function () {
      sidebar.classList.toggle('open');
    });

    // Close sidebar when clicking outside on mobile
    document.addEventListener('click', function (e) {
      if (window.innerWidth <= 768 &&
          !sidebar.contains(e.target) &&
          e.target !== sidebarToggle) {
        sidebar.classList.remove('open');
      }
    });
  }

  // Auto-dismiss toasts after 4s
  document.querySelectorAll('.toast').forEach(function (t) {
    setTimeout(function () {
      t.style.transition = 'opacity .3s';
      t.style.opacity    = '0';
      setTimeout(function () { t.remove(); }, 300);
    }, 4000);
  });
});

// ── Toast (JS-triggered) ─────────────────────────────────────────────────────
function showToast(type, message) {
  let wrap = document.querySelector('.toast-float-wrap');
  if (!wrap) {
    wrap = document.createElement('div');
    wrap.className = 'toast-float-wrap';
    document.body.appendChild(wrap);
  }

  const t   = document.createElement('div');
  t.className = `toast-float ${type}`;

  const icon = type === 'success' ? 'check-circle' : 'alert-circle';
  t.innerHTML = `
    <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24"
         fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"
         stroke-linejoin="round" data-feather="${icon}"></svg>
    <span>${message}</span>`;

  wrap.appendChild(t);
  feather.replace();

  setTimeout(function () {
    t.style.transition = 'opacity .3s, transform .3s';
    t.style.opacity    = '0';
    t.style.transform  = 'translateY(8px)';
    setTimeout(function () { t.remove(); }, 300);
  }, 3500);
}

// ── Copy to clipboard ────────────────────────────────────────────────────────
function copyText(text) {
  navigator.clipboard.writeText(text).then(function () {
    showToast('success', 'Copied to clipboard');
  }).catch(function () {
    // Fallback for older browsers
    const el       = document.createElement('textarea');
    el.value       = text;
    el.style.position = 'fixed';
    el.style.opacity  = '0';
    document.body.appendChild(el);
    el.select();
    document.execCommand('copy');
    document.body.removeChild(el);
    showToast('success', 'Copied to clipboard');
  });
}
