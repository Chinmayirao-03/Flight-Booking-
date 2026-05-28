# app.py — SkyRoute Flight Reservation System
# Full backend: search, book, cancel, coupons, transactions, passenger management

from flask import Flask, render_template, request, redirect, url_for, session, jsonify, flash
import mysql.connector
from mysql.connector import Error
from datetime import datetime, date
import random
import string
import os

app = Flask(__name__)
app.secret_key = 'skyroute-secret-2026'   # Change in production

# ── Database config ────────────────────────────────────────────
DB_CONFIG = {
    'host':     'localhost',
    'user':     'root',
    'password': 'Annapurna28!',   # ← update this
    'database': 'flight_reservation'
}

def get_db():
    conn = mysql.connector.connect(**DB_CONFIG)
    return conn

def query(sql, params=None, fetchone=False, commit=False):
    """Helper: run a query and return results or affected rows."""
    conn = get_db()
    cur  = conn.cursor(dictionary=True)
    try:
        cur.execute(sql, params or ())
        if commit:
            conn.commit()
            return cur.rowcount
        if fetchone:
            return cur.fetchone()
        return cur.fetchall()
    except Error as e:
        conn.rollback()
        raise e
    finally:
        cur.close()
        conn.close()

# ── Helpers ────────────────────────────────────────────────────
def seat_label(n):
    """Generate a seat label like 14C from a booking id."""
    row  = (n % 40) + 1
    col  = chr(65 + (n % 6))
    return f"{row}{col}"

def apply_coupon(coupon_code, base_price):
    """Validate coupon and return (coupon_row, discount_amount, error_msg)."""
    today = date.today().isoformat()
    coupon = query(
        """SELECT * FROM Coupon
           WHERE coupon_code = %s AND is_active = 1
             AND valid_from <= %s AND valid_until >= %s
             AND used_count < max_uses""",
        (coupon_code, today, today),
        fetchone=True
    )
    if not coupon:
        return None, 0, "Invalid or expired coupon code."
    if base_price < float(coupon['min_price']):
        return None, 0, f"Minimum booking amount for this coupon is ${coupon['min_price']:.2f}."
    if coupon['discount_type'] == 'PERCENTAGE':
        discount = round(base_price * float(coupon['discount_value']) / 100, 2)
    else:
        discount = float(coupon['discount_value'])
    discount = min(discount, base_price)   # never negative total
    return coupon, discount, None


# ── Route helpers ──────────────────────────────────────────────
FLIGHT_SELECT = """
    SELECT f.*,
           orig.city AS origin_city, orig.airport_code AS origin_code,
           dest.city AS dest_city,   dest.airport_code AS dest_code,
           ac.model  AS aircraft_model,
           TIMEDIFF(f.arrival_time, f.departure_time) AS duration
    FROM   Flight f
    JOIN   Airport orig ON f.origin_airport_id      = orig.airport_id
    JOIN   Airport dest ON f.destination_airport_id = dest.airport_id
    JOIN   Aircraft ac  ON f.aircraft_id            = ac.aircraft_id
"""


# ══════════════════════════════════════════════════════════════
#  PAGES
# ══════════════════════════════════════════════════════════════

@app.route('/')
def index():
    """Home / search page."""
    airports = query("SELECT * FROM Airport ORDER BY city")
    return render_template('index.html', airports=airports)


@app.route('/search')
def search():
    """Search results."""
    origin = request.args.get('origin', '').strip()
    dest   = request.args.get('destination', '').strip()
    date_s = request.args.get('date', '').strip()
    cls    = request.args.get('flight_class', '').strip()

    sql    = FLIGHT_SELECT + " WHERE f.status='Scheduled' AND f.available_seats > 0"
    params = []

    if origin:
        sql += " AND (orig.city LIKE %s OR orig.airport_code = %s)"
        params += [f"%{origin}%", origin.upper()]
    if dest:
        sql += " AND (dest.city LIKE %s OR dest.airport_code = %s)"
        params += [f"%{dest}%", dest.upper()]
    if date_s:
        sql += " AND DATE(f.departure_time) = %s"
        params.append(date_s)
    if cls:
        sql += " AND f.flight_class = %s"
        params.append(cls)

    sql += " ORDER BY f.departure_time"
    flights  = query(sql, params)
    airports = query("SELECT * FROM Airport ORDER BY city")
    return render_template('search.html', flights=flights, airports=airports,
                           q={'origin': origin, 'destination': dest,
                              'date': date_s, 'flight_class': cls})


@app.route('/flight/<int:flight_id>')
def flight_detail(flight_id):
    """Flight detail + booking form."""
    flight = query(FLIGHT_SELECT + " WHERE f.flight_id = %s", (flight_id,), fetchone=True)
    if not flight:
        flash("Flight not found.", "error")
        return redirect(url_for('index'))
    coupons = query("SELECT coupon_code, description, discount_type, discount_value FROM Coupon WHERE is_active=1 AND valid_until >= CURDATE()")
    return render_template('flight_detail.html', flight=flight, coupons=coupons)


@app.route('/api/validate-coupon', methods=['POST'])
def validate_coupon():
    """AJAX endpoint: validate a coupon for a given price."""
    data       = request.get_json()
    code       = data.get('coupon_code', '').strip().upper()
    base_price = float(data.get('base_price', 0))
    coupon, discount, err = apply_coupon(code, base_price)
    if err:
        return jsonify({'valid': False, 'message': err})
    return jsonify({
        'valid':       True,
        'discount':    discount,
        'final_price': round(base_price - discount, 2),
        'message':     f"Coupon applied! You save ${discount:.2f}",
        'coupon_id':   coupon['coupon_id']
    })


@app.route('/book', methods=['POST'])
def book():
    """Create a booking."""
    flight_id   = int(request.form['flight_id'])
    first_name  = request.form['first_name'].strip()
    last_name   = request.form['last_name'].strip()
    email       = request.form['email'].strip().lower()
    phone       = request.form.get('phone', '').strip()
    passport    = request.form['passport'].strip().upper()
    dob         = request.form.get('dob', None) or None
    nationality = request.form.get('nationality', '').strip()
    coupon_code = request.form.get('coupon_code', '').strip().upper()
    payment_method = request.form.get('payment_method', 'CREDIT_CARD')

    # ── Fetch flight ──
    flight = query("SELECT * FROM Flight WHERE flight_id = %s", (flight_id,), fetchone=True)
    if not flight:
        flash("Flight not found.", "error")
        return redirect(url_for('index'))
    if flight['available_seats'] <= 0:
        flash("Sorry, this flight is now fully booked.", "error")
        return redirect(url_for('flight_detail', flight_id=flight_id))

    # ── Upsert passenger ──
    existing = query("SELECT * FROM Passenger WHERE email = %s", (email,), fetchone=True)
    if existing:
        passenger_id = existing['passenger_id']
        query("UPDATE Passenger SET first_name=%s, last_name=%s, phone=%s WHERE passenger_id=%s",
              (first_name, last_name, phone, passenger_id), commit=True)
    else:
        conn = get_db()
        cur  = conn.cursor()
        try:
            cur.execute(
                "INSERT INTO Passenger (first_name,last_name,email,phone,passport_number,date_of_birth,nationality) VALUES (%s,%s,%s,%s,%s,%s,%s)",
                (first_name, last_name, email, phone, passport, dob, nationality)
            )
            conn.commit()
            passenger_id = cur.lastrowid
        except Error as e:
            conn.rollback()
            flash(f"Error saving passenger: {e}", "error")
            return redirect(url_for('flight_detail', flight_id=flight_id))
        finally:
            cur.close(); conn.close()

    # ── Check duplicate booking ──
    dup = query("SELECT * FROM Booking WHERE passenger_id=%s AND flight_id=%s AND status='CONFIRMED'",
                (passenger_id, flight_id), fetchone=True)
    if dup:
        flash("You already have a confirmed booking for this flight.", "warning")
        return redirect(url_for('my_bookings', email=email))

    # ── Apply coupon ──
    base_price   = float(flight['base_price'])
    discount     = 0.0
    coupon_id    = None
    coupon_msg   = ""
    if coupon_code:
        coupon, discount, err = apply_coupon(coupon_code, base_price)
        if err:
            flash(err, "warning")
            discount = 0.0
        else:
            coupon_id  = coupon['coupon_id']
            coupon_msg = f"Coupon {coupon_code} applied — saved ${discount:.2f}!"
    total_price = round(base_price - discount, 2)

    # ── Insert booking (triggers fire here) ──
    conn = get_db()
    cur  = conn.cursor()
    try:
        cur.execute(
            """INSERT INTO Booking
               (passenger_id,flight_id,seat_number,status,base_price,coupon_id,discount_amount,total_price,payment_status)
               VALUES (%s,%s,%s,'CONFIRMED',%s,%s,%s,%s,'PAID')""",
            (passenger_id, flight_id, None, base_price, coupon_id, discount, total_price)
        )
        conn.commit()
        booking_id = cur.lastrowid
        # assign seat label now we have the id
        seat = seat_label(booking_id)
        cur.execute("UPDATE Booking SET seat_number=%s WHERE booking_id=%s", (seat, booking_id))
        # Update transaction payment method
        cur.execute("UPDATE Transaction SET payment_method=%s WHERE booking_id=%s", (payment_method, booking_id))
        conn.commit()
    except Error as e:
        conn.rollback()
        flash(f"Booking failed: {e}", "error")
        return redirect(url_for('flight_detail', flight_id=flight_id))
    finally:
        cur.close(); conn.close()

    if coupon_msg:
        flash(coupon_msg, "success")
    flash(f"Booking confirmed! Your booking ID is #{booking_id}.", "success")
    return redirect(url_for('booking_confirmation', booking_id=booking_id))


@app.route('/booking/<int:booking_id>')
def booking_confirmation(booking_id):
    """Booking confirmation / ticket page."""
    booking = query(
        """SELECT b.*, p.first_name, p.last_name, p.email, p.passport_number, p.phone,
                  f.flight_number, f.departure_time, f.arrival_time, f.flight_class,
                  orig.city AS origin_city, orig.airport_code AS origin_code,
                  dest.city AS dest_city,   dest.airport_code AS dest_code,
                  ac.model AS aircraft_model,
                  c.coupon_code, t.payment_method, t.reference_number
           FROM Booking b
           JOIN Passenger p  ON b.passenger_id = p.passenger_id
           JOIN Flight f     ON b.flight_id    = f.flight_id
           JOIN Airport orig ON f.origin_airport_id      = orig.airport_id
           JOIN Airport dest ON f.destination_airport_id = dest.airport_id
           JOIN Aircraft ac  ON f.aircraft_id            = ac.aircraft_id
           LEFT JOIN Coupon c ON b.coupon_id = c.coupon_id
           LEFT JOIN Transaction t ON t.booking_id = b.booking_id AND t.transaction_type='PAYMENT'
           WHERE b.booking_id = %s""",
        (booking_id,), fetchone=True
    )
    if not booking:
        flash("Booking not found.", "error")
        return redirect(url_for('index'))
    return render_template('confirmation.html', booking=booking)


@app.route('/my-bookings')
def my_bookings():
    """Passenger bookings dashboard."""
    email = request.args.get('email', '').strip().lower()
    bookings = []
    passenger = None
    if email:
        passenger = query("SELECT * FROM Passenger WHERE email=%s", (email,), fetchone=True)
        if passenger:
            bookings = query(
                """SELECT b.*, f.flight_number, f.departure_time, f.arrival_time, f.flight_class,
                          orig.city AS origin_city, orig.airport_code AS origin_code,
                          dest.city AS dest_city,   dest.airport_code AS dest_code,
                          c.coupon_code,
                          cn.refund_amount, cn.refund_status
                   FROM Booking b
                   JOIN Flight f     ON b.flight_id = f.flight_id
                   JOIN Airport orig ON f.origin_airport_id      = orig.airport_id
                   JOIN Airport dest ON f.destination_airport_id = dest.airport_id
                   LEFT JOIN Coupon c      ON b.coupon_id      = c.coupon_id
                   LEFT JOIN Cancellation cn ON cn.booking_id  = b.booking_id
                   WHERE b.passenger_id = %s
                   ORDER BY b.booking_date DESC""",
                (passenger['passenger_id'],)
            )
        else:
            flash("No account found with that email.", "warning")
    return render_template('my_bookings.html', bookings=bookings,
                           passenger=passenger, email=email)


@app.route('/cancel/<int:booking_id>', methods=['POST'])
def cancel_booking(booking_id):
    """Cancel a booking (trigger handles seat restore + refund log)."""
    email  = request.form.get('email', '').strip().lower()
    reason = request.form.get('reason', 'Cancelled by passenger').strip()

    booking = query(
        "SELECT b.*, p.email FROM Booking b JOIN Passenger p ON b.passenger_id=p.passenger_id WHERE b.booking_id=%s",
        (booking_id,), fetchone=True
    )
    if not booking:
        flash("Booking not found.", "error")
        return redirect(url_for('my_bookings', email=email))
    if booking['email'] != email:
        flash("Unauthorized cancellation attempt.", "error")
        return redirect(url_for('my_bookings', email=email))
    if booking['status'] == 'CANCELLED':
        flash("This booking is already cancelled.", "warning")
        return redirect(url_for('my_bookings', email=email))

    # Update trigger fires: restores seat, logs Cancellation, logs refund Transaction
    try:
        query("UPDATE Booking SET status='CANCELLED' WHERE booking_id=%s", (booking_id,), commit=True)
        # Update cancellation reason (trigger inserted with default)
        query("UPDATE Cancellation SET reason=%s WHERE booking_id=%s", (reason, booking_id), commit=True)
        flash(f"Booking #{booking_id} cancelled. Refund (85%) will be processed within 5–7 business days.", "success")
    except Error as e:
        flash(f"Cancellation failed: {e}", "error")

    return redirect(url_for('my_bookings', email=email))


@app.route('/transactions/<int:booking_id>')
def transactions(booking_id):
    """Transaction history for a booking."""
    email = request.args.get('email', '')
    txns  = query(
        """SELECT t.*, b.booking_id, f.flight_number,
                  p.first_name, p.last_name
           FROM Transaction t
           JOIN Booking b  ON t.booking_id   = b.booking_id
           JOIN Flight f   ON b.flight_id    = f.flight_id
           JOIN Passenger p ON b.passenger_id = p.passenger_id
           WHERE t.booking_id = %s
           ORDER BY t.transaction_date""",
        (booking_id,)
    )
    return render_template('transactions.html', txns=txns,
                           booking_id=booking_id, email=email)


@app.route('/deals')
def deals():
    """Active coupons / deals page."""
    coupons = query(
        "SELECT * FROM Coupon WHERE is_active=1 AND valid_until >= CURDATE() ORDER BY discount_value DESC"
    )
    return render_template('deals.html', coupons=coupons)


@app.route('/api/flights')
def api_flights():
    """JSON API for all scheduled flights (used by JS on home page)."""
    flights = query(
        FLIGHT_SELECT + " WHERE f.status='Scheduled' ORDER BY f.departure_time LIMIT 50"
    )
    for f in flights:
        for k, v in f.items():
            if isinstance(v, datetime):
                f[k] = v.strftime('%Y-%m-%d %H:%M')
            elif hasattr(v, 'seconds'):   # timedelta duration
                h, rem = divmod(v.seconds, 3600)
                m = rem // 60
                f[k] = f"{h}h {m}m"
    return jsonify(flights)


if __name__ == '__main__':
    app.run(port=3000, debug=True)