const app = document.getElementById('app');
if (window.__syntheticModeratorReady !== true) {
  app.textContent = 'Local UI fixture stopped. Use a fresh isolated browser context without a wallet extension. The application was not started.';
} else {
  const banner = document.createElement('p');
  banner.textContent = 'LOCAL UI TEST: synthetic wallet and chain; no real transactions.';
  banner.setAttribute('role', 'note');
  document.body.prepend(banner);
  await import('./loader.js');
}
