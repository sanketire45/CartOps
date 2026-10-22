import { Link, useLocation } from 'react-router-dom'

const styles = {
  nav: {
    background: '#1a1a2e',
    padding: '0 24px',
    display: 'flex',
    alignItems: 'center',
    height: 56,
    gap: 32,
  },
  brand: {
    color: '#e94560',
    fontWeight: 700,
    fontSize: 20,
    textDecoration: 'none',
    marginRight: 'auto',
  },
  link: {
    color: '#ccc',
    textDecoration: 'none',
    fontSize: 15,
    fontWeight: 500,
    padding: '4px 0',
  },
  active: {
    color: '#fff',
    borderBottom: '2px solid #e94560',
  },
}

export default function Navbar() {
  const { pathname } = useLocation()

  const linkStyle = (path) => ({
    ...styles.link,
    ...(pathname.startsWith(path) ? styles.active : {}),
  })

  return (
    <nav style={styles.nav}>
      <Link to="/products" style={styles.brand}>🛒 EcomStore</Link>
      <Link to="/products" style={linkStyle('/products')}>Products</Link>
      <Link to="/orders" style={linkStyle('/orders')}>Place Order</Link>
    </nav>
  )
}
