import { useState, useEffect } from 'react'

const s = {
  h1: { fontSize: 26, fontWeight: 700, marginBottom: 4 },
  subtitle: { color: '#666', marginBottom: 24, fontSize: 14 },
  section: {
    background: '#fff', borderRadius: 10, padding: 24,
    boxShadow: '0 2px 8px rgba(0,0,0,0.08)', maxWidth: 560, marginBottom: 36,
  },
  sectionTitle: { fontSize: 18, fontWeight: 700, marginBottom: 16 },
  row: { display: 'flex', gap: 12, marginBottom: 16 },
  field: { flex: 1, display: 'flex', flexDirection: 'column', gap: 4 },
  label: { fontWeight: 600, fontSize: 13 },
  input: { padding: '9px 12px', borderRadius: 6, border: '1px solid #ddd', fontSize: 14 },
  select: { padding: '9px 12px', borderRadius: 6, border: '1px solid #ddd', fontSize: 14 },
  btn: {
    padding: '10px 24px', background: '#e94560', color: '#fff',
    border: 'none', borderRadius: 6, cursor: 'pointer', fontWeight: 700, fontSize: 15,
  },
  msg: { marginTop: 12, padding: '10px 14px', borderRadius: 6, fontWeight: 600, fontSize: 14 },
  successMsg: { background: '#ecfdf5', color: '#065f46' },
  errorMsg: { background: '#fef2f2', color: '#991b1b' },
  grid: { display: 'grid', gridTemplateColumns: 'repeat(auto-fill, minmax(200px, 1fr))', gap: 16 },
  card: {
    background: '#fff', borderRadius: 10, padding: 16,
    boxShadow: '0 2px 8px rgba(0,0,0,0.08)',
  },
  idBadge: {
    display: 'inline-block', background: '#1a1a2e', color: '#fff',
    borderRadius: 4, padding: '2px 8px', fontSize: 12, marginBottom: 6,
  },
  title: { fontWeight: 600, fontSize: 14, marginBottom: 4 },
  price: { color: '#e94560', fontWeight: 700, fontSize: 18 },
  brand: { color: '#888', fontSize: 12 },
}

export default function Products() {
  const [products, setProducts] = useState([])
  const [categories, setCategories] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)

  const [form, setForm] = useState({ title: '', brand: '', price: '', discount: '0', categoryId: '' })
  const [submitting, setSubmitting] = useState(false)
  const [msg, setMsg] = useState(null)
  const [isSuccess, setIsSuccess] = useState(false)

  const loadProducts = () => {
    setLoading(true)
    setError(null)
    fetch('/api/products')
      .then(r => r.ok ? r.json() : Promise.reject(r.status))
      .then(data => { setProducts(data); setLoading(false) })
      .catch(e => { setError(`Failed to load products (${e})`); setLoading(false) })
  }

  useEffect(() => {
    fetch('/api/categories')
      .then(r => r.ok ? r.json() : Promise.reject(r.status))
      .then(data => {
        setCategories(data)
        if (data.length > 0) setForm(f => ({ ...f, categoryId: String(data[0].id) }))
      })
      .catch(() => {})
    loadProducts()
  }, [])

  const handleChange = e => setForm(f => ({ ...f, [e.target.name]: e.target.value }))

  const handleCreate = async (e) => {
    e.preventDefault()
    setSubmitting(true)
    setMsg(null)
    try {
      const res = await fetch('/api/products', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          title: form.title,
          brand: form.brand,
          price: Number(form.price),
          discount: Number(form.discount),
          categoryId: Number(form.categoryId),
        }),
      })
      const data = await res.json()
      if (!res.ok) throw new Error(data.message || res.status)
      setIsSuccess(true)
      setMsg(`Product #${data.id} "${data.title}" created — use this ID in the Orders page`)
      setForm(f => ({ ...f, title: '', brand: '', price: '', discount: '0' }))
      loadProducts()
    } catch (err) {
      setIsSuccess(false)
      setMsg(`Failed: ${err.message}`)
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <div>
      <h1 style={s.h1}>Products</h1>
      <p style={s.subtitle}>Create products here, then use their ID in the Orders page to place an order.</p>

      <div style={s.section}>
        <p style={s.sectionTitle}>Create Product</p>
        <form onSubmit={handleCreate}>
          <div style={s.row}>
            <div style={s.field}>
              <label style={s.label}>Title</label>
              <input style={s.input} name="title" value={form.title} onChange={handleChange} placeholder="e.g. Gaming Laptop" required />
            </div>
            <div style={s.field}>
              <label style={s.label}>Brand</label>
              <input style={s.input} name="brand" value={form.brand} onChange={handleChange} placeholder="e.g. Dell" required />
            </div>
          </div>
          <div style={s.row}>
            <div style={s.field}>
              <label style={s.label}>Price ($)</label>
              <input style={s.input} name="price" type="number" min="1" value={form.price} onChange={handleChange} required />
            </div>
            <div style={s.field}>
              <label style={s.label}>Discount (%)</label>
              <input style={s.input} name="discount" type="number" min="0" max="100" value={form.discount} onChange={handleChange} />
            </div>
            <div style={s.field}>
              <label style={s.label}>Category</label>
              <select style={s.select} name="categoryId" value={form.categoryId} onChange={handleChange} required>
                {categories.map(c => <option key={c.id} value={c.id}>{c.name}</option>)}
              </select>
            </div>
          </div>
          <button style={s.btn} type="submit" disabled={submitting}>
            {submitting ? 'Creating…' : 'Create Product'}
          </button>
          {msg && (
            <div style={{ ...s.msg, ...(isSuccess ? s.successMsg : s.errorMsg) }}>{msg}</div>
          )}
        </form>
      </div>

      <p style={s.sectionTitle}>{products.length} Products in catalogue</p>
      {loading && <p style={{ color: '#888' }}>Loading…</p>}
      {error && <p style={{ color: '#e94560' }}>{error}</p>}
      {!loading && !error && products.length === 0 && (
        <p style={{ color: '#888' }}>No products yet — create one above.</p>
      )}
      {!loading && !error && (
        <div style={s.grid}>
          {products.map(p => (
            <div key={p.id} style={s.card}>
              <span style={s.idBadge}>ID: {p.id}</span>
              <p style={s.title}>{p.title}</p>
              <p style={s.brand}>{p.brand}</p>
              <p style={s.price}>${p.price}</p>
              {p.discount > 0 && <span style={{ fontSize: 12, color: '#27ae60' }}>{p.discount}% off</span>}
            </div>
          ))}
        </div>
      )}
    </div>
  )
}
