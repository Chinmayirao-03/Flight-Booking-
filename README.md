# ✦ SkyRoute — Full-Stack Flight Reservation System

A production-grade flight booking website built with **Python Flask**, **MySQL**, and **HTML/CSS/JS**.

---

## ✈ Features

| Feature | Details |
|---|---|
| **Flight Search** | Filter by origin, destination, date, class |
| **Book Flights** | Passenger details, seat auto-assignment |
| **Coupon Codes** | AJAX validation, percentage & flat discounts |
| **Cancel Bookings** | 85% refund policy, reason capture |
| **My Bookings** | Email-based dashboard, status tracking |
| **E-Ticket** | Full ticket view with booking reference |
| **Transactions** | Auto-generated payment & refund records |
| **Deals Page** | Browse & copy active coupon codes |
| **DB Triggers** | Seat count auto-update, cancellation log, refund transaction |
| **Normalization** | 3NF schema: Airport, Aircraft, Flight, Passenger, Booking, Coupon, Cancellation, Transaction |

---

## 📁 Project Structure

```
skyroute/
│
├── app.py                        ← Flask backend (all routes)
├── schema.sql                    ← Full DB schema + triggers + sample data
├── requirements.txt
├── README.md
│
├── templates/
│   ├── base.html                 ← Navbar, flash messages, footer
│   ├── index.html                ← Home + hero search
│   ├── search.html               ← Search results
│   ├── flight_detail.html        ← Flight info + booking form
│   ├── confirmation.html         ← E-ticket after booking
│   ├── my_bookings.html          ← Passenger dashboard + cancel
│   ├── deals.html                ← Active coupons
│   └── transactions.html         ← Payment/refund history
│
└── static/
    ├── css/style.css             ← Full dark-luxury stylesheet
    └── js/main.js                ← Animations, coupon UX, toasts
```

---

## 🚀 Setup (5 steps)

### 1. Install Python packages
```bash
pip install -r requirements.txt
```

### 2. Create the database
```bash
mysql -u root -p < schema.sql
```
Or paste `schema.sql` contents into MySQL Workbench and run it.

### 3. Update DB credentials in `app.py`
```python
DB_CONFIG = {
    'host':     'localhost',
    'user':     'root',
    'password': 'YOUR_PASSWORD',   # ← change this
    'database': 'flight_reservation'
}
```

### 4. Run the server
```bash
python app.py
```

### 5. Open in browser
```
http://127.0.0.1:5000
```

---

## 🏷 Sample Coupon Codes

| Code | Discount | Min. Booking |
|---|---|---|
| `WELCOME10` | 10% off | $100 |
| `FLAT50` | $50 flat off | $200 |
| `SUMMER20` | 20% off | $300 |
| `BUSINESS15` | 15% off | $500 |
| `FIRST100` | $100 flat off | $800 |

---

## 🗄 Database Triggers

| Trigger | Event | Action |
|---|---|---|
| `trg_before_booking_insert` | BEFORE INSERT Booking | Block if no seats |
| `trg_after_booking_insert` | AFTER INSERT Booking | Decrease available_seats; increment coupon used_count |
| `trg_after_booking_cancel` | AFTER UPDATE Booking → CANCELLED | Restore seat; insert Cancellation; decrement coupon |
| `trg_after_booking_txn` | AFTER INSERT Booking | Auto-create PAYMENT Transaction |
| `trg_after_cancel_refund_txn` | AFTER INSERT Cancellation | Auto-create REFUND Transaction |

---

## 🔗 Key Routes

| Route | Method | Description |
|---|---|---|
| `/` | GET | Home page with search form |
| `/search` | GET | Search results with filters |
| `/flight/<id>` | GET | Flight detail + booking form |
| `/api/validate-coupon` | POST | AJAX coupon validation |
| `/book` | POST | Create booking |
| `/booking/<id>` | GET | E-ticket / confirmation |
| `/my-bookings` | GET | Passenger dashboard |
| `/cancel/<id>` | POST | Cancel a booking |
| `/transactions/<id>` | GET | Transaction history |
| `/deals` | GET | Active coupon deals |
| `/api/flights` | GET | JSON API for all flights |

---

## 💡 How a Booking Works (end to end)

1. User searches flights → `/search`
2. Clicks "Book Now" → `/flight/<id>` shows details + coupon field
3. Coupon validated via AJAX → `/api/validate-coupon`
4. Form submitted → `/book` (POST)
   - Passenger upserted into `Passenger` table
   - Duplicate booking check
   - Coupon discount calculated
   - `Booking` row inserted → **trigger fires** → `available_seats -= 1`
   - **Trigger fires** → `Transaction` row (PAYMENT) auto-created
5. Redirected to `/booking/<id>` — e-ticket shown

## 💡 How a Cancellation Works

1. User visits `/my-bookings?email=...`
2. Clicks "Cancel" → modal with reason
3. Form submits to `/cancel/<id>` (POST)
   - `Booking.status` updated to `CANCELLED`
   - **Trigger fires** → `available_seats += 1`
   - **Trigger fires** → `Cancellation` row inserted (85% refund)
   - **Trigger fires** → `Transaction` row (REFUND) auto-created
