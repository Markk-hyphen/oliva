import 'bootstrap/dist/css/bootstrap.min.css'
import './style.css'
import './js/setup.js'
import { initLive } from './js/live.js'

// Navbar scroll effect
document.addEventListener('DOMContentLoaded', initLive)

const navbar = document.getElementById('navbar')
window.addEventListener('scroll', () => {
  navbar.classList.toggle('scrolled', window.scrollY > 50)
}, { passive: true })
