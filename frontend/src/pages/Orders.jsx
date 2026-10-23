import { useState, useEffect } from 'react'

const s = {
  h1: { fontSize: 26, fontWeight: 700, marginBottom: 4 },
  subtitle: { color: '#666', marginBottom: 24, fontSize: 14 },
  section: {
    background: '#fff', borderRadius: 10, padding: 24,
    boxShadow: '0 2px 8px rgba(0,0,0,0.08)', maxWidth: 520, marginBottom: 32,
  },
  sectionTitle: { fontSize: 18, fontWeight: 700, marginBottom: 16 },
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
  secondaryBtn: {
    padding: '10px 24px', background: '#1a1a2e', color: '#fff',
    border: 'none', borderRadius: 6, cursor: 'pointer', fontWeight: 700, fontSize: 15,
  },
  msg: { marginTop: 14, padding: '10px 14px', borderRadius: 6, fontWeight: 600, fontSize: 14 },
  successMsg: { background: '#ecfdf5', color: '#065f46' },
  errorMsg: { background: '#fef2f2', color: '#991b1b' },
  orderCard: {
    background: '#f8f9fa', borderRadius: 8, padding: '14px 18px',
    marginBottom: 12, borderLeft: '4px solid #e94560',
  },
  orderHeader: { display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 },
  orderId: { fontWeight: 700, fontSize: 15 },
  status: {
    padding: '3px 10px', borderRadius: 20, fontSize: 12, fontWeight: 700,
    background: '#ecfdf5', color: '#065f46',
  },
  itemRow: { fontSize: 13, color: '#555', marginBottom: 3 },
  total: { fontWeight: 700, color: '#e94560', marginTop: 6 },
}

export default function Orders() {
  const [userId, setUserId] = useState('1')
  const [productId, setProductId] = useState('')
  const [quantity, setQuantity] = useState('1')
  const [submitting, setSubmitting] = useState(false)
  const [message, setMessage] = useState(null)
  const [isSuccess, setIsSuccess] = useState(false)

  const [historyUserId, setHistoryUserId] = useState('1')
  const [orders, setOrders] = useState([])
  const [loadingHistory, setLoadingHistory] = useState(false)
  const [historyError, setHistoryError] = useState(null)

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
      setHistoryUserId(userId)
      fetchHistory(userId)
    } catch (err) {
      setIsSuccess(false)
      setMessage(`Order failed: ${err.message}`)
    } finally {
      setSubmitting(false)
    }
  }

  const fetchHistory = async (overrideUserId) => {
    const uid = overrideUserId ?? historyUserId
    setLoadingHistory(true)
    setHistoryError(null)
    setOrders([])
    try {
      const res = await fetch(`/api/orders/${uid}`)
      if (!res.ok) throw new Error(res.status)
      const data = await res.json()
      setOrders(data)
    } catch (err) {
      setHistoryError(`Failed to load orders (${err.message})`)
    } finally {
      setLoadingHistory(false)
    }
  }

  return (
    <div>
      <h1 style={s.h1}>Orders</h1>
      <p style={s.subtitle}>Place an order for a product, then view order history by User ID.</p>

      <div style={s.section}>
        <p style={s.sectionTitle}>Place an Order</p>
        <form onSubmit={handleSubmit}>
          <label style={s.label}>User ID</label>
          <input style={s.input} type="number" min="1" value={userId} onChange={e => setUserId(e.target.value)} required />

          <label style={s.label}>Product ID</label>
          <input style={s.input} type="number" min="1" placeholder="Get this from the Products page" value={productId} onChange={e => setProductId(e.target.value)} required />

          <label style={s.label}>Quantity</label>
          <input style={s.input} type="number" min="1" value={quantity} onChange={e => setQuantity(e.target.value)} required />

          <button style={s.btn} type="submit" disabled={submitting}>
            {submitting ? 'Placing…' : 'Place Order'}
          </button>

          {message && (
            <div style={{ ...s.msg, ...(isSuccess ? s.successMsg : s.errorMsg) }}>
              {message}
            </div>
          )}
        </form>
      </div>

      <div style={{ ...s.section, maxWidth: 620 }}>
        <p style={s.sectionTitle}>Order History</p>
        <div style={{ display: 'flex', gap: 12, marginBottom: 16, alignItems: 'flex-end' }}>
          <div style={{ flex: 1 }}>
            <label style={s.label}>User ID</label>
            <input
              style={{ ...s.input, marginBottom: 0 }}
              type="number" min="1" value={historyUserId}
              onChange={e => setHistoryUserId(e.target.value)}
            />
          </div>
          <button style={s.secondaryBtn} onClick={fetchHistory} disabled={loadingHistory}>
            {loadingHistory ? 'Loading…' : 'Load Orders'}
          </button>
        </div>

        {historyError && <p style={{ color: '#e94560', fontSize: 14 }}>{historyError}</p>}

        {!loadingHistory && orders.length === 0 && !historyError && (
          <p style={{ color: '#888', fontSize: 14 }}>No orders loaded — click Load Orders.</p>
        )}

        {orders.map(order => (
          <div key={order.orderId} style={s.orderCard}>
            <div style={s.orderHeader}>
              <span style={s.orderId}>Order #{order.orderId}</span>
              <span style={s.status}>{order.status}</span>
            </div>
            {order.items && order.items.map((item, i) => (
              <p key={i} style={s.itemRow}>
                Product #{item.productId} — qty {item.quantity} × ${item.pricePerUnit.toFixed(2)} = ${item.totalPrice.toFixed(2)}
              </p>
            ))}
            <p style={s.total}>Total: ${order.totalAmount.toFixed(2)}</p>
          </div>
        ))}
      </div>

      <div style={{ background: '#fff8e1', borderRadius: 8, padding: '14px 18px', maxWidth: 620 }}>
        <p style={{ fontWeight: 600, marginBottom: 6 }}>How this works (interview talking point)</p>
        <p style={{ fontSize: 14, color: '#555', lineHeight: 1.6 }}>
          Frontend → Ingress (<code>/api/orders</code>) → Order service → Feign client calls
          <code>/api/products/{'{id}'}</code> on the product service via <strong>Eureka discovery</strong> (no hardcoded host).
          Order and items stored in MySQL (StatefulSet + PVC). History via <code>GET /api/orders/{'{userId}'}</code>.
        </p>
      </div>
    </div>
  )
}
