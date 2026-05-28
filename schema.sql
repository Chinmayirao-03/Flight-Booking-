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
('SK909', 6, 10, 1,'2026-07-18 09:00:00', '2026-07-19 06:00:00',  950.00, 20, 'Business'),
('SK111', 10, 7, 4, '2026-07-19 22:00:00', '2026-07-20 08:00:00',  320.00, 50, 'Economy'),
('SK222', 6, 9, 2, '2026-07-20 12:00:00', '2026-07-20 20:30:00',  450.00, 40, 'Economy');

INSERT INTO Flight (flight_number, origin_airport_id, destination_airport_id, aircraft_id, departure_time, arrival_time, base_price, available_seats, flight_class) VALUES
('SK223', 1, 3, 1, '2026-07-20 06:00:00', '2026-07-20 09:00:00', 188.00, 20, 'First'),
('SK224', 1, 4, 2, '2026-07-20 08:00:00', '2026-07-20 12:07:00', 222.00, 23, 'Economy'),
('SK225', 1, 5, 3, '2026-07-20 10:00:00', '2026-07-20 15:14:00', 256.00, 26, 'Business'),
('SK226', 2, 1, 4, '2026-07-20 12:00:00', '2026-07-20 18:21:00', 222.00, 29, 'Business'),
('SK227', 2, 4, 5, '2026-07-20 14:00:00', '2026-07-20 21:28:00', 290.00, 32, 'First'),
('SK228', 2, 5, 1, '2026-07-20 16:00:00', '2026-07-21 00:35:00', 324.00, 35, 'Economy'),
('SK229', 2, 6, 2, '2026-07-20 18:00:00', '2026-07-20 21:42:00', 358.00, 38, 'Business'),
('SK230', 3, 1, 3, '2026-07-20 20:00:00', '2026-07-21 00:49:00', 307.00, 41, 'Business'),
('SK231', 3, 2, 4, '2026-07-20 00:00:00', '2026-07-20 05:56:00', 341.00, 44, 'First'),
('SK232', 3, 5, 5, '2026-07-20 02:00:00', '2026-07-20 08:03:00', 409.00, 47, 'Economy'),
('SK233', 3, 6, 1, '2026-07-21 04:00:00', '2026-07-21 11:10:00', 443.00, 50, 'Business'),
('SK234', 4, 1, 2, '2026-07-21 06:00:00', '2026-07-21 14:17:00', 392.00, 53, 'Business'),
('SK235', 4, 2, 3, '2026-07-21 08:00:00', '2026-07-21 11:24:00', 426.00, 56, 'First'),
('SK236', 4, 3, 4, '2026-07-21 10:00:00', '2026-07-21 14:31:00', 460.00, 59, 'Economy'),
('SK237', 4, 6, 5, '2026-07-21 12:00:00', '2026-07-21 17:38:00', 528.00, 62, 'Business'),
('SK238', 5, 1, 1, '2026-07-21 14:00:00', '2026-07-21 20:45:00', 477.00, 65, 'Business'),
('SK239', 5, 2, 2, '2026-07-21 16:00:00', '2026-07-21 23:52:00', 511.00, 68, 'First'),
('SK240', 5, 3, 3, '2026-07-21 18:00:00', '2026-07-22 02:59:00', 545.00, 71, 'Economy'),
('SK241', 5, 4, 4, '2026-07-21 20:00:00', '2026-07-21 23:06:00', 579.00, 74, 'Business'),
('SK242', 6, 1, 5, '2026-07-21 00:00:00', '2026-07-21 04:13:00', 562.00, 77, 'First'),
('SK243', 6, 2, 1, '2026-07-22 02:00:00', '2026-07-22 07:20:00', 596.00, 80, 'Economy'),
('SK244', 6, 3, 2, '2026-07-22 04:00:00', '2026-07-22 10:27:00', 630.00, 83, 'Business'),
('SK245', 7, 1, 3, '2026-07-22 06:00:00', '2026-07-22 13:34:00', 630.00, 86, 'Business'),
('SK246', 7, 2, 4, '2026-07-22 08:00:00', '2026-07-22 16:41:00', 664.00, 89, 'First'),
('SK247', 7, 3, 5, '2026-07-22 10:00:00', '2026-07-22 13:48:00', 698.00, 92, 'Economy'),
('SK248', 7, 4, 1, '2026-07-22 12:00:00', '2026-07-22 16:55:00', 132.00, 95, 'Business'),
('SK249', 8, 1, 2, '2026-07-22 14:00:00', '2026-07-22 19:02:00', 715.00, 98, 'Business'),
('SK250', 8, 2, 3, '2026-07-22 16:00:00', '2026-07-22 22:09:00', 149.00, 21, 'First'),
('SK251', 8, 4, 4, '2026-07-22 18:00:00', '2026-07-23 01:16:00', 200.00, 24, 'Economy'),
('SK252', 8, 5, 5, '2026-07-22 20:00:00', '2026-07-23 04:23:00', 234.00, 27, 'Business'),
('SK253', 9, 2, 1, '2026-07-23 00:00:00', '2026-07-23 03:30:00', 217.00, 30, 'Business'),
('SK254', 9, 3, 2, '2026-07-23 02:00:00', '2026-07-23 06:37:00', 251.00, 33, 'First'),
('SK255', 9, 4, 3, '2026-07-23 04:00:00', '2026-07-23 09:44:00', 285.00, 36, 'Economy'),
('SK256', 9, 5, 4, '2026-07-23 06:00:00', '2026-07-23 12:51:00', 319.00, 39, 'Business'),
('SK257', 10, 1, 5, '2026-07-23 08:00:00', '2026-07-23 15:58:00', 285.00, 42, 'Business'),
('SK258', 10, 2, 1, '2026-07-23 10:00:00', '2026-07-23 18:05:00', 319.00, 45, 'First'),
('SK259', 10, 3, 2, '2026-07-23 12:00:00', '2026-07-23 15:12:00', 353.00, 48, 'Economy'),
('SK260', 10, 4, 3, '2026-07-23 14:00:00', '2026-07-23 18:19:00', 387.00, 51, 'Business'),
('SK261', 1, 6, 4, '2026-07-23 16:00:00', '2026-07-23 21:26:00', 285.00, 54, 'Business'),
('SK262', 1, 7, 5, '2026-07-23 18:00:00', '2026-07-24 00:33:00', 319.00, 57, 'Business'),
('SK263', 2, 7, 1, '2026-07-24 20:00:00', '2026-07-25 03:40:00', 353.00, 60, 'First'),
('SK264', 3, 7, 2, '2026-07-24 00:00:00', '2026-07-24 08:47:00', 387.00, 63, 'Economy'),
('SK265', 4, 7, 3, '2026-07-24 02:00:00', '2026-07-24 05:54:00', 421.00, 66, 'Business'),
('SK266', 1, 8, 4, '2026-07-24 04:00:00', '2026-07-24 08:01:00', 404.00, 69, 'Business'),
('SK267', 2, 8, 5, '2026-07-24 06:00:00', '2026-07-24 11:08:00', 438.00, 72, 'First'),
('SK268', 3, 8, 1, '2026-07-24 08:00:00', '2026-07-24 14:15:00', 472.00, 75, 'Economy'),
('SK269', 4, 8, 2, '2026-07-24 10:00:00', '2026-07-24 17:22:00', 506.00, 78, 'Business'),
('SK270', 1, 9, 3, '2026-07-24 12:00:00', '2026-07-24 20:29:00', 489.00, 81, 'Business'),
('SK271', 2, 9, 4, '2026-07-24 14:00:00', '2026-07-24 17:36:00', 523.00, 84, 'First'),
('SK272', 3, 9, 5, '2026-07-24 16:00:00', '2026-07-24 20:43:00', 557.00, 87, 'Economy'),
('SK273', 4, 9, 1, '2026-07-25 18:00:00', '2026-07-25 23:50:00', 591.00, 90, 'Business'),
('SK274', 1, 10, 2, '2026-07-25 20:00:00', '2026-07-26 02:57:00', 574.00, 93, 'Business'),
('SK275', 2, 10, 3, '2026-07-25 00:00:00', '2026-07-25 07:04:00', 608.00, 96, 'First'),
('SK276', 3, 10, 4, '2026-07-25 02:00:00', '2026-07-25 10:11:00', 642.00, 99, 'Economy'),
('SK277', 4, 10, 5, '2026-07-25 04:00:00', '2026-07-25 07:18:00', 676.00, 22, 'Business');

INSERT INTO Coupon (coupon_code, description, discount_type, discount_value, min_price, max_uses, valid_from, valid_until) VALUES
('WELCOME10',  '10% off for new users',         'PERCENTAGE', 10.00,  100.00, 500, '2026-01-01', '2026-12-31'),
('FLAT50',     'Flat $50 off on any booking',   'FLAT',       50.00,  200.00, 200, '2026-01-01', '2026-12-31'),
('SUMMER20',   '20% summer sale discount',      'PERCENTAGE', 20.00,  300.00, 300, '2026-06-01', '2026-08-31'),
('BUSINESS15', '15% off Business class',        'PERCENTAGE', 15.00,  500.00, 100, '2026-01-01', '2026-12-31'),
('FIRST100',   'Flat $100 off First class',     'FLAT',      100.00,  800.00,  50, '2026-01-01', '2026-12-31');