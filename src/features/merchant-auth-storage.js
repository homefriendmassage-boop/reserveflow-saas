export function merchantAuthStorage(rememberDevice) {
  return {
    getItem(key) {
      return sessionStorage.getItem(key) ?? (key.endsWith('-code-verifier') ? null : localStorage.getItem(key));
    },
    setItem(key, value) {
      const shared = !key.endsWith('-code-verifier') &&
        (rememberDevice() || localStorage.getItem(key) !== null);
      if (shared) {
        localStorage.setItem(key, value);
        sessionStorage.removeItem(key);
      } else {
        sessionStorage.setItem(key, value);
      }
    },
    removeItem(key) {
      sessionStorage.removeItem(key);
      if (!key.endsWith('-code-verifier')) localStorage.removeItem(key);
    }
  };
}
