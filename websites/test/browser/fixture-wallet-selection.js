// Synthetic EIP-6963 wallets. Never uses a key, extension, or remote RPC.
(() => {
  if (window.ethereum) return;
  const mode = "__MODE__";
  const authorizationEvent = __AUTH_EVENT__;
  const listeners = new Map();
  const removalFailures = new Set();
  const registrationFailures = new Set();
  const providers = new Map();
  function wallet(id) {
    if (providers.has(id)) return providers.get(id);
    const events = new Map(); listeners.set(id, events);
    const provider = {
      on(name, fn) {
        if (!events.has(name)) events.set(name, new Set());
        events.get(name).add(fn);
        if (registrationFailures.has(id)) throw new Error('Synthetic registration failure');
      },
      removeListener(name, fn) {
        if (removalFailures.has(id)) throw new Error('Synthetic cleanup failure');
        events.get(name)?.delete(fn);
      },
      async request(request) {
        const response = await fetch('/fixture/wallet', {method:'POST', headers:{'Content-Type':'application/json'},
          body:JSON.stringify({method:request.method, params:[id, ...(request.params || [])]})});
        const value = await response.json();
        if (value.error) throw value.error;
        if (authorizationEvent && request.method === 'eth_requestAccounts') {
          for (const fn of events.get('accountsChanged') || []) fn(value.result);
        }
        return value.result;
      }
    };
    providers.set(id, provider); return provider;
  }
  const alpha = wallet('alpha'), beta = wallet('beta');
  let defaultId = mode === 'multi' ? 'beta' : ['none', 'announced-only'].includes(mode) ? 'none' : 'alpha';
  Object.defineProperty(window, 'ethereum', {value:defaultId === 'none' ? undefined : wallet(defaultId), configurable:false, writable:mode !== 'none'});
  function announce(id, info) {
    const uuid = id === 'alpha' ? '11111111-1111-4111-8111-111111111111' : '22222222-2222-4222-8222-222222222222';
    const metadata = Object.freeze(info || {uuid, name:id === 'alpha' ? 'Alpha Wallet' : 'Beta Wallet', rdns:'test.' + id,
      icon:'data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg" onload="throw 1" />'});
    window.dispatchEvent(new CustomEvent('eip6963:announceProvider', {detail:Object.freeze({info:metadata,provider:wallet(id)})}));
  }
  window.addEventListener('eip6963:requestProvider', () => {
    if (mode === 'multi' || mode === 'single' || mode === 'announced-only') announce('alpha');
    if (mode === 'multi') announce('beta');
  });
  window.__syntheticModeratorReady = true;
  setInterval(async () => {
    try {
      for (const event of await (await fetch('/fixture/events')).json()) {
        if (event.kind === 'replace-default') { defaultId=event.provider; window.ethereum=wallet(defaultId); }
        if (event.kind === 'emit') for (const fn of listeners.get(event.provider)?.get(event.name) || []) fn(event.value);
        if (event.kind === 'remove-failure') event.enabled ? removalFailures.add(event.provider) : removalFailures.delete(event.provider);
        if (event.kind === 'register-failure') event.enabled ? registrationFailures.add(event.provider) : registrationFailures.delete(event.provider);
        if (event.kind === 'late-beta') announce('beta');
        if (event.kind === 'long-name') announce('gamma', {uuid:'33333333-3333-4333-8333-333333333333',name:'Long wallet name '.repeat(20),rdns:'test.gamma',icon:'https://invalid.test/no-fetch'});
        if (event.kind === 'duplicate') {
          announce('alpha');
          announce('beta', {uuid:'11111111-1111-4111-8111-111111111111',name:'<script>Fake wallet</script>',rdns:'test.invalid',icon:'https://invalid.test/no-fetch'});
        }
        const counts = Object.fromEntries([...listeners].map(([id, events]) => [id,Object.fromEntries([...events].map(([name, fns])=>[name,fns.size]))]));
        await fetch('/fixture/wallet', {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({method:'fixture_ack',params:[{seq:event.seq,defaultId,listeners:counts}]})});
      }
    } catch { /* A stopped fixture cannot contact another provider. */ }
  }, 150);
})();
