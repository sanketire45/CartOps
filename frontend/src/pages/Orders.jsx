import { useState, useEffect } from 'react'

const styles = {
  h1: { fontSize: 26, fontWeight: 700, marginBottom: 4 },
  subtitle: { color: '#666', marginBottom: 24, fontSize: 14 },
  form: {
    background: '#fff', borderRadius: 10, padding: 24,
    boxShadow: '0 2px 8px rgba(0,0,0,0.08)', maxWidth: 520, marginBottom: 32,
  },
  label: { display: 'block', fontWeight: 600, marginBottom: 6, fontSize: 14 },
  input: {
    width: '100%', padding: '10px 12px', borderRadius: 6,
    border: '1px solid #ddd', fontSize: 14, marginBottom: 16,
  },
  row: { display: 'flex', gap: 12 },
  btn: {
    padding: '10px 24px', background: '#e94560', color: '#fff',
    border: 'none', borderRadius: 6, cursor: 'pointer', fontWeight: 700, fontSize: 15,
  },
  msg: { marginTop: 14, padding: '10px 14px', borderRadius: 6, fontWeight: 600, fontSize: 14 },
  successMsg: { background: '#ecfdf5', color: '#065f46' },
  errorMsg: { background: '#fef2f2', color: '#991b1b' },
}

export default function Orders() {
  const [userId, setUserId] = useState('1')
  const [productId, setProductId] = useState('')
  const [quantity, setQuantity] = useState('1')
  const [submitting, setSubmitting] = useState(false)
  const [message, setMessage] = useState(null)
  const [isSuccess, setIsSuccess] = useState(false)

  const handleSubmit = async (e) => {
    e.preventDefault()
    setSubmitting(true)
    setMessage(null)
    try {
      const res = await fetch('/api/orders', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          userId: Number(userId),
          items: [{ productId: Number(productId), quantity: Number(quantity) }],
        }),
      })
      const data = await res.json()
      if (!res.ok) throw new Error(data.message || res.status)
      setIsSuccess(true)
      setMessage(`Order #${data.orderId} created — status: ${data.status}`)
      setProductId('')
      setQuantity('1')
    } catch (err) {
      setIsSuccess(false)
      setMessage(`Order failed: ${err.message}`)
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <div>
      <h1 style={styles.h1}>Place an Order</h1>
      <p style={styles.subtitle}>The order service (port 7878) validates the product via Feign → product service.</p>

      <form style={styles.form} onSubmit={handleSubmit}>
        <label style={styles.label}>User ID</label>
        <input style={styles.input} type="number" min="1" value={userId} onChange={e => setUserId(e.target.value)} required />

        <label style={styles.label}>Product ID</label>
        <input style={styles.input} type="number" min="1" placeholder="e.g. 1" value={productId} onChange={e => setProductId(e.target.value)} required />

        <label style={styles.label}>Quantity</label>
        <input style={styles.input} type="number" min="1" value={quantity} onChange={e => setQuantity(e.target.value)} required />

        <button style={styles.btn} type="submit" disabled={submitting}>
          {submitting ? 'Placing…' : 'Place Order'}
        </button>

        {message && (
          <div style={{ ...styles.msg, ...(isSuccess ? styles.successMsg : styles.errorMsg) }}>
            {message}
          </div>
        )}
      </form>

      <div style={{ background: '#fff8e1', borderRadius: 8, padding: '14px 18px', maxWidth: 520 }}>
        <p style={{ fontWeight: 600, marginBottom: 6 }}>How this works (interview talking point)</p>
        <p style={{ fontSize: 14, color: '#555', lineHeight: 1.6 }}>
          Frontend → Ingress (<code>/api/orders</code>) → Order service → Feign client calls
          <code>/api/products/{'{'}id{'}'}</code> on the product service via <strong>Eureka discovery</strong> (no hardcoded host).
          Order stores result in MySQL (StatefulSet + PVC).
        </p>
      </div>
    </div>
  )
}
