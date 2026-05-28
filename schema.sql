-- ============================================================
-- schema.sql — SkyRoute Full Database Schema
-- ============================================================

CREATE DATABASE IF NOT EXISTS flight_reservation;
USE flight_reservation;

-- ============================================================
-- TABLES
-- ============================================================

CREATE TABLE IF NOT EXISTS Airport (
    airport_id   INT AUTO_INCREMENT PRIMARY KEY,
    airport_code CHAR(3)      NOT NULL UNIQUE,
    airport_name VARCHAR(100) NOT NULL,
    city         VARCHAR(50)  NOT NULL,
    country      VARCHAR(50)  NOT NULL
);

CREATE TABLE IF NOT EXISTS Aircraft (
    aircraft_id  INT AUTO_INCREMENT PRIMARY KEY,
    model        VARCHAR(50)  NOT NULL,
    total_seats  INT          NOT NULL
);

CREATE TABLE IF NOT EXISTS Flight (
    flight_id               INT AUTO_INCREMENT PRIMARY KEY,
    flight_number           VARCHAR(10)   NOT NULL UNIQUE,
    origin_airport_id       INT           NOT NULL,
    destination_airport_id  INT           NOT NULL,
    aircraft_id             INT           NOT NULL,
    departure_time          DATETIME      NOT NULL,
    arrival_time            DATETIME      NOT NULL,
    base_price              DECIMAL(10,2) NOT NULL,
    available_seats         INT           NOT NULL,
    flight_class            ENUM('Economy','Business','First') NOT NULL DEFAULT 'Economy',
    status                  ENUM('Scheduled','Delayed','Cancelled','Completed') NOT NULL DEFAULT 'Scheduled',
    CONSTRAINT fk_origin      FOREIGN KEY (origin_airport_id)      REFERENCES Airport(airport_id) ON UPDATE CASCADE,
    CONSTRAINT fk_dest        FOREIGN KEY (destination_airport_id) REFERENCES Airport(airport_id) ON UPDATE CASCADE,
    CONSTRAINT fk_aircraft    FOREIGN KEY (aircraft_id)            REFERENCES Aircraft(aircraft_id) ON UPDATE CASCADE
);

CREATE TABLE IF NOT EXISTS Passenger (
    passenger_id    INT AUTO_INCREMENT PRIMARY KEY,
    first_name      VARCHAR(50)  NOT NULL,
    last_name       VARCHAR(50)  NOT NULL,
    email           VARCHAR(100) NOT NULL UNIQUE,
    phone           VARCHAR(20),
    passport_number VARCHAR(20)  NOT NULL UNIQUE,
    date_of_birth   DATE,
    nationality     VARCHAR(50),
    created_at      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS Coupon (
    coupon_id       INT AUTO_INCREMENT PRIMARY KEY,
    coupon_code     VARCHAR(20)   NOT NULL UNIQUE,
    description     VARCHAR(200),
    discount_type   ENUM('PERCENTAGE','FLAT') NOT NULL,
    discount_value  DECIMAL(10,2) NOT NULL,   -- e.g. 10 = 10% or $10 flat
    min_price       DECIMAL(10,2) NOT NULL DEFAULT 0,
    max_uses        INT           NOT NULL DEFAULT 100,
    used_count      INT           NOT NULL DEFAULT 0,
    valid_from      DATE          NOT NULL,
    valid_until     DATE          NOT NULL,
    is_active       TINYINT(1)    NOT NULL DEFAULT 1
);

CREATE TABLE IF NOT EXISTS Booking (
    booking_id      INT AUTO_INCREMENT PRIMARY KEY,
    passenger_id    INT           NOT NULL,
    flight_id       INT           NOT NULL,
    booking_date    DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    seat_number     VARCHAR(5),
    status          ENUM('CONFIRMED','CANCELLED','PENDING') NOT NULL DEFAULT 'CONFIRMED',
    base_price      DECIMAL(10,2) NOT NULL,
    coupon_id       INT           DEFAULT NULL,
    discount_amount DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    total_price     DECIMAL(10,2) NOT NULL,
    payment_status  ENUM('PAID','REFUNDED','PENDING') NOT NULL DEFAULT 'PAID',
    CONSTRAINT uq_pax_flight UNIQUE (passenger_id, flight_id),
    CONSTRAINT fk_book_pax   FOREIGN KEY (passenger_id) REFERENCES Passenger(passenger_id) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT fk_book_flt   FOREIGN KEY (flight_id)    REFERENCES Flight(flight_id)    ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_book_coup  FOREIGN KEY (coupon_id)    REFERENCES Coupon(coupon_id)    ON DELETE SET NULL  ON UPDATE CASCADE
);

CREATE TABLE IF NOT EXISTS Cancellation (
    cancellation_id   INT AUTO_INCREMENT PRIMARY KEY,
    booking_id        INT           NOT NULL UNIQUE,
    cancellation_date DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    reason            VARCHAR(255),
    refund_amount     DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    refund_status     ENUM('PENDING','PROCESSED','DENIED') NOT NULL DEFAULT 'PENDING',
    CONSTRAINT fk_cancel_book FOREIGN KEY (booking_id) REFERENCES Booking(booking_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS Transaction (
    transaction_id   INT AUTO_INCREMENT PRIMARY KEY,
    booking_id       INT           NOT NULL,
    transaction_date DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    amount           DECIMAL(10,2) NOT NULL,
    transaction_type ENUM('PAYMENT','REFUND','PARTIAL_REFUND') NOT NULL,
    payment_method   ENUM('CREDIT_CARD','DEBIT_CARD','UPI','NET_BANKING','WALLET') NOT NULL DEFAULT 'CREDIT_CARD',
    status           ENUM('SUCCESS','FAILED','PENDING') NOT NULL DEFAULT 'SUCCESS',
    reference_number VARCHAR(50),
    CONSTRAINT fk_txn_book FOREIGN KEY (booking_id) REFERENCES Booking(booking_id) ON DELETE CASCADE
);

-- ============================================================
-- TRIGGERS
-- ============================================================

DELIMITER $$

-- TRIGGER 1: Block booking if no seats left
CREATE TRIGGER trg_before_booking_insert
BEFORE INSERT ON Booking
FOR EACH ROW
BEGIN
    DECLARE seats INT;
    SELECT available_seats INTO seats FROM Flight WHERE flight_id = NEW.flight_id;
    IF seats <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'No seats available on this flight.';
    END IF;
END$$

-- TRIGGER 2: Decrease seats after confirmed booking
CREATE TRIGGER trg_after_booking_insert
AFTER INSERT ON Booking
FOR EACH ROW
BEGIN
    IF NEW.status = 'CONFIRMED' THEN
        UPDATE Flight SET available_seats = available_seats - 1
        WHERE flight_id = NEW.flight_id;
        -- Increment coupon used_count if applied
        IF NEW.coupon_id IS NOT NULL THEN
            UPDATE Coupon SET used_count = used_count + 1 WHERE coupon_id = NEW.coupon_id;
        END IF;
    END IF;
END$$

-- TRIGGER 3: On cancellation — restore seat, auto-log cancellation, mark refund
CREATE TRIGGER trg_after_booking_cancel
AFTER UPDATE ON Booking
FOR EACH ROW
BEGIN
    IF OLD.status = 'CONFIRMED' AND NEW.status = 'CANCELLED' THEN
        -- Restore seat to flight
        UPDATE Flight SET available_seats = available_seats + 1
        WHERE flight_id = NEW.flight_id;
        -- Log cancellation with 85% refund
        INSERT INTO Cancellation (booking_id, reason, refund_amount, refund_status)
        VALUES (NEW.booking_id, 'Cancelled by passenger', ROUND(NEW.total_price * 0.85, 2), 'PENDING');
        -- Decrement coupon used_count if applied
        IF NEW.coupon_id IS NOT NULL THEN
            UPDATE Coupon SET used_count = GREATEST(used_count - 1, 0) WHERE coupon_id = NEW.coupon_id;
        END IF;
    END IF;
END$$

-- TRIGGER 4: Auto-create Transaction record after Booking insert
CREATE TRIGGER trg_after_booking_txn
AFTER INSERT ON Booking
FOR EACH ROW
BEGIN
    IF NEW.status = 'CONFIRMED' THEN
        INSERT INTO Transaction (booking_id, amount, transaction_type, payment_method, status, reference_number)
        VALUES (NEW.booking_id, NEW.total_price, 'PAYMENT', 'CREDIT_CARD', 'SUCCESS',
                CONCAT('TXN', LPAD(NEW.booking_id, 8, '0'), FLOOR(RAND()*1000)));
    END IF;
END$$

-- TRIGGER 5: Auto-create refund Transaction on cancellation log insert
CREATE TRIGGER trg_after_cancel_refund_txn
AFTER INSERT ON Cancellation
FOR EACH ROW
BEGIN
    INSERT INTO Transaction (booking_id, amount, transaction_type, payment_method, status, reference_number)
    VALUES (NEW.booking_id, NEW.refund_amount, 'REFUND', 'CREDIT_CARD', 'SUCCESS',
            CONCAT('REF', LPAD(NEW.booking_id, 8, '0'), FLOOR(RAND()*1000)));
END$$

DELIMITER ;

-- ============================================================
-- SAMPLE DATA
-- ============================================================

INSERT INTO Airport (airport_code, airport_name, city, country) VALUES
('JFK', 'John F. Kennedy International', 'New York',    'USA'),
('LHR', 'Heathrow Airport',              'London',      'UK'),
('DXB', 'Dubai International',           'Dubai',       'UAE'),
('SIN', 'Changi Airport',                'Singapore',   'Singapore'),
('NRT', 'Narita International',          'Tokyo',       'Japan'),
('LAX', 'Los Angeles International',     'Los Angeles', 'USA'),
('BOM', 'Chhatrapati Shivaji Maharaj',   'Mumbai',      'India'),
('DEL', 'Indira Gandhi International',   'New Delhi',   'India'),
('CDG', 'Charles de Gaulle',             'Paris',       'France'),
('SYD', 'Kingsford Smith',               'Sydney',      'Australia');

INSERT INTO Aircraft (model, total_seats) VALUES
('Boeing 777',   300),
('Airbus A380',  500),
('Boeing 737',   180),
('Airbus A320',  150),
('Boeing 787',   240);

INSERT INTO Flight (flight_number, origin_airport_id, destination_airport_id, aircraft_id, departure_time, arrival_time, base_price, available_seats, flight_class) VALUES
('SK101', 1, 2, 1, '2026-07-10 08:00:00', '2026-07-10 20:00:00',  549.99, 45, 'Economy'),
('SK102', 1, 2, 1, '2026-07-10 20:00:00', '2026-07-11 08:00:00',  849.99, 30, 'Business'),
('SK202', 2, 3, 2, '2026-07-11 11:30:00', '2026-07-11 21:00:00',  399.00,  8, 'Economy'),
('SK303', 3, 4, 1, '2026-07-12 14:00:00', '2026-07-13 02:30:00',  310.50, 60, 'Economy'),
('SK404', 4, 5, 3, '2026-07-13 09:00:00', '2026-07-13 16:00:00',  275.00, 22, 'Economy'),
('SK505', 5, 6, 4, '2026-07-14 17:00:00', '2026-07-14 11:00:00',  820.00,  5, 'Business'),
('SK606', 7, 8, 3, '2026-07-15 06:00:00', '2026-07-15 08:10:00',   89.99, 80, 'Economy'),
('SK707', 8, 3, 5, '2026-07-16 22:00:00', '2026-07-17 10:00:00',  420.00, 35, 'Economy'),
('SK808', 9, 1, 2, '2026-07-17 13:00:00', '2026-07-17 15:30:00',  680.00, 15, 'First'),
('SK909', 6, 10, 1,'2026-07-18 09:00:00', '2026-07-19 06:00:00',  950.00, 20, 'Business');

INSERT INTO Coupon (coupon_code, description, discount_type, discount_value, min_price, max_uses, valid_from, valid_until) VALUES
('WELCOME10',  '10% off for new users',         'PERCENTAGE', 10.00,  100.00, 500, '2026-01-01', '2026-12-31'),
('FLAT50',     'Flat $50 off on any booking',   'FLAT',       50.00,  200.00, 200, '2026-01-01', '2026-12-31'),
('SUMMER20',   '20% summer sale discount',      'PERCENTAGE', 20.00,  300.00, 300, '2026-06-01', '2026-08-31'),
('BUSINESS15', '15% off Business class',        'PERCENTAGE', 15.00,  500.00, 100, '2026-01-01', '2026-12-31'),
('FIRST100',   'Flat $100 off First class',     'FLAT',      100.00,  800.00,  50, '2026-01-01', '2026-12-31');
