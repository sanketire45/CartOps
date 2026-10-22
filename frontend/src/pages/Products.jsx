import { useState, useEffect } from 'react'
import { Link } from 'react-router-dom'

const styles = {
  toolbar: { display: 'flex', gap: 12, marginBottom: 24, flexWrap: 'wrap', alignItems: 'center' },
  select: { padding: '8px 12px', borderRadius: 6, border: '1px solid #ddd', fontSize: 14 },
  grid: { display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(220px, 1fr))', gap: 20 },
  card: {
    background: '#fff', borderRadius: 10, padding: 16, boxShadow: '0 2px 8px rgba(0,0,0,0.08)',
    display: 'flex', flexDirection: 'column', gap: 8,
  },
  img: { width: '100%', height: 180, objectFit: 'contain', borderRadius: 6 },
  title: { fontWeight: 600, fontSize: 14, lineHeight: 1.4, height: 40, overflow: 'hidden' },
  price: { color: '#e94560', fontWeight: 700, fontSize: 18 },
  badge: {
    display: 'inline-block', background: '#f0f0f0', borderRadius: 4,
    padding: '2px 8px', fontSize: 12, color: '#555',
  },
  btn: {
    marginTop: 'auto', padding: '8px 0', background: '#1a1a2e', color: '#fff',
    border: 'none', borderRadius: 6, cursor: 'pointer', fontSize: 14, fontWeight: 600,
    textDecoration: 'none', textAlign: 'center',
  },
  error: { color: '#e94560', padding: '32px 0' },
  loading: { color: '#888', padding: '32px 0' },
  h1: { fontSize: 26, fontWeight: 700, marginBottom: 4 },
  subtitle: { color: '#666', marginBottom: 20, fontSize: 14 },
}

export default function Products() {
  const [products, setProducts] = useState([])
  const [categories, setCategories] = useState([])
  const [selectedCategory, setSelectedCategory] = useState('')
  const [limit, setLimit] = useState(12)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)

  useEffect(() => {
    fetch('/api/categories')
      .then(r => r.ok ? r.json() : Promise.reject(r.status))
      .then(setCategories)
      .catch(() => {})
  }, [])

  useEffect(() => {
    setLoading(true)
    setError(null)
    fetch(`/api/products?limit=${limit}`)
      .then(r => r.ok ? r.json() : Promise.reject(r.status))
      .then(data => { setProducts(data); setLoading(false) })
      .catch(e => { setError(`Failed to load products (${e})`); setLoading(false) })
  }, [limit])

  const visible = selectedCategory
    ? products.filter(p => p.category === selectedCategory)
    : products

  return (
    <div>
      <h1 style={styles.h1}>Product Catalogue</h1>
      <p style={styles.subtitle}>{visible.length} products</p>

      <div style={styles.toolbar}>
        <select style={styles.select} value={selectedCategory} onChange={e => setSelectedCategory(e.target.value)}>
          <option value="">All categories</option>
          {categories.map(c => (
            <option key={c.id ?? c.name} value={c.name}>{c.name}</option>
          ))}
        </select>

        <select style={styles.select} value={limit} onChange={e => setLimit(Number(e.target.value))}>
          {[6, 12, 24].map(n => <option key={n} value={n}>Show {n}</option>)}
        </select>
      </div>

      {loading && <p style={styles.loading}>Loading products…</p>}
      {error && <p style={styles.error}>{error}</p>}

      {!loading && !error && (
        <div style={styles.grid}>
          {visible.map(p => (
            <div key={p.id} style={styles.card}>
              {p.image && <img src={p.image} alt={p.title} style={styles.img} />}
              <p style={styles.title}>{p.title}</p>
              <span style={styles.badge}>{p.category}</span>
              <p style={styles.price}>${p.price}</p>
              {p.discount > 0 && <span style={{ ...styles.badge, color: '#27ae60' }}>{p.discount}% off</span>}
              <Link to={`/products/${p.id}`} style={styles.btn}>View Details</Link>
            </div>
          ))}
        </div>
      )}
    </div>
  )
}
