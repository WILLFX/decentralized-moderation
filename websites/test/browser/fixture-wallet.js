// Test-only provider. Never permit the application to use a real wallet.
(() => {
  if (window.ethereum) return;
  let authoringStorageFault = false;
  let historyStorageFault = false;
  if (window.__syntheticFixtureEvents === true && typeof Storage !== 'undefined') {
    const original = Storage.prototype.setItem;
    Storage.prototype.setItem = function(key, value) {
      if (historyStorageFault && this === window.localStorage && key.startsWith('swarm-publisher-last-') && key.endsWith('-history')) throw new Error('Synthetic history storage failure');
      if (authoringStorageFault && this === window.sessionStorage && key === 'swarm-publisher-authoring-v1') throw new Error('Synthetic tab storage failure');
      return original.call(this,key,value);
    };
  }
  const listeners = new Map();
  const provider = {
    isMetaMask: true,
    on(name, fn) { listeners.set(name, fn); },
    removeListener(name, fn) {
      if (listeners.get(name) === fn) listeners.delete(name);
    },
    async request(request) {
      const response = await fetch('/fixture/wallet', {
        method: 'POST', headers: {'Content-Type': 'application/json'},
        body: JSON.stringify(request)
      });
      const result = await response.json();
      if (result.error) throw result.error;
      return result.result;
    }
  };
  // A later extension injection cannot replace the synthetic provider.
  Object.defineProperty(window, 'ethereum', {
    value: provider, writable: false, configurable: false
  });
  window.__syntheticModeratorReady = true;
  if (window.__syntheticFixtureEvents === true) {
    setInterval(async () => {
      try {
        const response = await fetch('/fixture/events');
        for (const event of await response.json()) {
          if (event.name === 'fixtureHistoryStorageFault') historyStorageFault = event.value === true;
          else if (event.name === 'fixtureHistorySeed') { window.localStorage.setItem(event.value.key, event.value.raw); }
          else if (event.name === 'fixtureAuthoringStorageFault') authoringStorageFault = event.value === true;
          else listeners.get(event.name)?.(event.value);
        }
      } catch { /* Observer unavailable; never contact another provider. */ }
    }, 200);
  }
})();
