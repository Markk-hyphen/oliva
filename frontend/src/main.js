import 'bootstrap/dist/css/bootstrap.min.css'
import './style.css'
import './js/setup.js'

// Navbar scroll effect
const navbar = document.getElementById('navbar')
window.addEventListener('scroll', () => {
  navbar.classList.toggle('scrolled', window.scrollY > 50)
}, { passive: true })
