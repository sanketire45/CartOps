import { useState, useEffect } from 'react'
import { useParams, Link, useNavigate } from 'react-router-dom'

const styles = {
  back: { color: '#1a1a2e', textDecoration: 'none', fontSize: 14, display: 'inline-block', marginBottom: 20 },
  card: {
    background: '#fff', borderRadius: 12, padding: 32, boxShadow: '0 2px 12px rgba(0,0,0,0.1)',
    display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 40, maxWidth: 900,
  },
  img: { width: '100%', maxHeight: 360, objectFit: 'contain', borderRadius: 8 },
  title: { fontSize: 24, fontWeight: 700, marginBottom: 8, lineHeight: 1.3 },
  price: { fontSize: 28, color: '#e94560', fontWeight: 700, margin: '12px 0' },
  badge: { display: 'inline-block', background: '#f0f0f0', borderRadius: 4, padding: '3px 10px', fontSize: 13, color: '#555', marginRight: 8 },
  desc: { color: '#555', lineHeight: 1.6, marginTop: 12 },
  row: { display: 'flex', gap: 8, flexWrap: 'wrap', margin: '12px 0' },
  orderBtn: {
    marginTop: 24, padding: '12px 24px', background: '#e94560', color: '#fff',
    border: 'none', borderRadius: 8, cursor: 'pointer', fontSize: 16, fontWeight: 600,
  },
  loading: { color: '#888', padding: '32px 0' },
  error: { color: '#e94560', padding: '32px 0' },
}

export default function ProductDetail() {
  const { id } = useParams()
  const navigate = useNavigate()
  const [product, setProduct] = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [orderMsg, setOrderMsg] = useState(null)

  useEffect(() => {
    fetch(`/api/products/${id}/details`)
      .then(r => r.ok ? r.json() : Promise.reject(r.status))
      .then(data => { setProduct(data); setLoading(false) })
      .catch(e => { setError(`Product not found (${e})`); setLoading(false) })
  }, [id])

  const placeOrder = async () => {
    try {
      const res = await fetch('/api/orders', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ userId: 1, items: [{ productId: Number(id), quantity: 1 }] }),
      })
      if (!res.ok) throw new Error(res.status)
      const data = await res.json()
      setOrderMsg(`Order #${data.orderId} placed — status: ${data.status}`)
    } catch (e) {
      setOrderMsg(`Order failed: ${e.message}`)
    }
  }

  if (loading) return <p style={styles.loading}>Loading…</p>
  if (error) return <p style={styles.error}>{error}</p>

  return (
    <div>
      <Link to="/products" style={styles.back}>← Back to catalogue</Link>
      <div style={styles.card}>
        <div>
          {product.image && <img src={product.image} alt={product.title} style={styles.img} />}
        </div>
        <div>
          <h1 style={styles.title}>{product.title}</h1>
          <div style={styles.row}>
            <span style={styles.badge}>{product.category}</span>
            {product.brand && <span style={styles.badge}>{product.brand}</span>}
            {product.popular && <span style={{ ...styles.badge, background: '#fef9c3', color: '#92400e' }}>Popular</span>}
          </div>
          <p style={styles.price}>${product.price}</p>
          {product.discount > 0 && <p style={{ color: '#27ae60', fontWeight: 600 }}>{product.discount}% discount applied</p>}
          {product.model && <p style={{ color: '#777', fontSize: 14 }}>Model: {product.model}</p>}
          {product.color && <p style={{ color: '#777', fontSize: 14 }}>Color: {product.color}</p>}
          <p style={styles.desc}>{product.description}</p>
          <button style={styles.orderBtn} onClick={placeOrder}>Place Order</button>
          {orderMsg && <p style={{ marginTop: 12, color: orderMsg.startsWith('Order #') ? '#27ae60' : '#e94560', fontWeight: 600 }}>{orderMsg}</p>}
        </div>
      </div>
    </div>
  )
}
