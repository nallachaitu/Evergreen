/*
 * Copyright (C) 2011  Equinox Software, Inc.
 * Mike Rylander <miker@esilibrary.com>
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 */

INSERT INTO config.upgrade_log(version) VALUES ('1.6.2.3');

CREATE OR REPLACE VIEW money.open_billable_xact_summary AS
    SELECT  xact.id AS id,
        xact.usr AS usr,
        COALESCE(circ.circ_lib,groc.billing_location,res.pickup_lib) AS billing_location,
        xact.xact_start AS xact_start,
        xact.xact_finish AS xact_finish,
        SUM(credit.amount) AS total_paid,
        MAX(credit.payment_ts) AS last_payment_ts,
        LAST(credit.note) AS last_payment_note,
        LAST(credit.payment_type) AS last_payment_type,
        SUM(debit.amount) AS total_owed,
        MAX(debit.billing_ts) AS last_billing_ts,
        LAST(debit.note) AS last_billing_note,
        LAST(debit.billing_type) AS last_billing_type,
        COALESCE(SUM(debit.amount),0) - COALESCE(SUM(credit.amount),0) AS balance_owed,
        p.relname AS xact_type
      FROM  money.billable_xact xact
        JOIN pg_class p ON (xact.tableoid = p.oid)
        LEFT JOIN "action".circulation circ ON (circ.id = xact.id)
        LEFT JOIN money.grocery groc ON (groc.id = xact.id)
        LEFT JOIN booking.reservation res ON (res.id = xact.id)
        LEFT JOIN (
            SELECT  billing.xact,
                billing.voided,
                sum(billing.amount) AS amount,
                max(billing.billing_ts) AS billing_ts,
                last(billing.note) AS note,
                last(billing.billing_type) AS billing_type
              FROM  money.billing
              WHERE billing.voided IS FALSE
              GROUP BY billing.xact, billing.voided
        ) debit ON (xact.id = debit.xact AND debit.voided IS FALSE)
        LEFT JOIN (
            SELECT  payment_view.xact,
                payment_view.voided,
                sum(payment_view.amount) AS amount,
                max(payment_view.payment_ts) AS payment_ts,
                last(payment_view.note) AS note,
                last(payment_view.payment_type) AS payment_type
              FROM  money.payment_view
              WHERE payment_view.voided IS FALSE
              GROUP BY payment_view.xact, payment_view.voided
        ) credit ON (xact.id = credit.xact AND credit.voided IS FALSE)
      WHERE xact.xact_finish IS NULL
      GROUP BY 1,2,3,4,5,15
      ORDER BY MAX(debit.billing_ts), MAX(credit.payment_ts);

