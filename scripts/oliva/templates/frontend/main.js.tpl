import './style.css'

// Proof that the frontend reaches the backend through the gateway. Replace it.
fetch('/health')
  .then((r) => r.json())
  .then((d) => { document.getElementById('health').textContent = d.status })
  .catch(() => { document.getElementById('health').textContent = 'unreachable' })
