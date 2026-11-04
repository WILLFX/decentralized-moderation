// Bootstrap only. The existing Rust application owns all participant workflows.
const page = document.documentElement;
page.dataset.bootState = 'loading';
performance.mark('swarm-bootstrap-start');
const retry = document.getElementById('boot-retry');
retry?.addEventListener('click', () => location.reload());
try {
  // Start both transfers together; the wrapper must not delay the Wasm request.
  const [bindings, response] = await Promise.all([
    import('./swarm_moderator.js'),
    fetch(new URL('./swarm_moderator_bg.wasm', document.baseURI)),
  ]);
  if (!response.ok) throw new Error('APPLICATION_ASSET_UNAVAILABLE');
  performance.mark('swarm-assets-received');
  await bindings.default({ module_or_path: response });
  const main = document.querySelector('main');
  main.removeAttribute('inert');
  main.removeAttribute('aria-busy');
  document.getElementById('boot')?.remove();
  retry?.remove();
  page.dataset.bootState = 'ready';
  performance.mark('swarm-ready');
} catch (error) {
  page.dataset.bootState = 'error';
  const boot = document.getElementById('boot');
  if (boot) boot.textContent = 'Swarm Review could not start. Reload to try again.';
  if (retry) retry.hidden = false;
  console.error('Application startup failed', error);
}
