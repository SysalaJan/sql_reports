WITH RECURSIVE
prescasy AS (
    SELECT
        pe.*,
        nd.id AS nalezene_id_davky
    FROM process_executions pe

    LEFT JOIN LATERAL (
        SELECT MIN(bx.id) AS id
        FROM batches bx
        WHERE bx.production_batch = TRUE
          AND bx.number = BTRIM(
              pe.free_attributes ->> 'batch_number'
          )
        HAVING COUNT(*) = 1
    ) nd ON TRUE

    WHERE pe.process_definition_id = 190
),

vychozi_davky AS (
    SELECT DISTINCT
        nalezene_id_davky AS id_davky
    FROM prescasy
    WHERE nalezene_id_davky IS NOT NULL
),

navaznosti (vychozi_id, id_davky) AS (
    SELECT
        id_davky,
        id_davky
    FROM vychozi_davky

    UNION

    SELECT
        n.vychozi_id,
        m.using_supply_id
    FROM navaznosti n

    JOIN planning_output.supply_demand_matches m
        ON m.used_supply_id = n.id_davky
       AND m.is_batch = TRUE

    WHERE m.using_supply_id IS NOT NULL
),

planovane_objednavky AS (
    SELECT DISTINCT
        n.vychozi_id,
        soi.sales_order_id
    FROM navaznosti n

    JOIN planning_output.supply_demand_matches m
        ON m.used_supply_id = n.id_davky
       AND m.is_batch = TRUE

    JOIN sales_order_items soi
        ON soi.id = m.demand_id

    WHERE m.using_supply_id IS NULL
      AND soi.sales_order_id IS NOT NULL
),

prime_objednavky AS (
    SELECT
        n.vychozi_id,
        soi.sales_order_id
    FROM navaznosti n

    JOIN batches nb
        ON nb.id = n.id_davky

    JOIN sales_order_items soi
        ON soi.id = nb.sales_order_item_id

    WHERE soi.sales_order_id IS NOT NULL

    UNION

    SELECT
        n.vychozi_id,
        so.id
    FROM navaznosti n

    JOIN batches nb
        ON nb.id = n.id_davky

    JOIN sales_orders so
        ON so.id = ANY(nb.consuming_sales_order_ids)
),

vazby_objednavek AS (
    SELECT
        vychozi_id,
        sales_order_id
    FROM planovane_objednavky

    UNION

    SELECT
        pr.vychozi_id,
        pr.sales_order_id
    FROM prime_objednavky pr

    WHERE NOT EXISTS (
        SELECT 1
        FROM planovane_objednavky pl
        WHERE pl.vychozi_id = pr.vychozi_id
    )
),

souhrn_objednavek AS (
    SELECT
        v.vychozi_id,

        STRING_AGG(
            so.id::text,
            ', ' ORDER BY so.id
        ) AS cisla_objednavek,

        COUNT(*) AS pocet,
        MIN(so.id) AS jedina_objednavka

    FROM vazby_objednavek v

    JOIN sales_orders so
        ON so.id = v.sales_order_id

    GROUP BY v.vychozi_id
),

cisla_stroju AS (
    SELECT
        v.vychozi_id,

        NULLIF(
            BTRIM(so.free_attributes ->> 'MACHINE_NO'),
            ''
        ) AS cislo

    FROM vazby_objednavek v

    JOIN sales_orders so
        ON so.id = v.sales_order_id

    UNION

    SELECT
        n.vychozi_id,

        NULLIF(
            BTRIM(sn.serial_number),
            ''
        ) AS cislo

    FROM navaznosti n

    JOIN batch_serial_numbers sn
        ON sn.batch_id = n.id_davky
),

souhrn_stroju AS (
    SELECT
        vychozi_id,

        STRING_AGG(
            DISTINCT cislo,
            ', ' ORDER BY cislo
        ) AS vyrobni_cisla

    FROM cisla_stroju
    WHERE cislo IS NOT NULL
    GROUP BY vychozi_id
),

casy_prescasu AS (
    SELECT
        pe.id AS proces_id,
        pe.entity_id AS person_id,

        NULLIF(
            BTRIM(pe.free_attributes ->> 'overtime_from'),
            ''
        )::timestamp AS od,

        NULLIF(
            BTRIM(pe.free_attributes ->> 'overtime_to'),
            ''
        )::timestamp AS konec

    FROM prescasy pe
),

automaticke_zaznamy AS (
    SELECT DISTINCT
        ar.id

    FROM casy_prescasu cp

    JOIN process_step_executions pse
        ON pse.process_execution_id = cp.proces_id

    JOIN process_step_definitions psd
        ON psd.id = pse.process_step_definition_id
       AND psd.type IN (
           'FILL_TASK',
           'AUTOMATIC_FILL_TASK'
       )

    JOIN attendance_records ar
        ON ar.person_id = cp.person_id

       AND (
           (ar.type = 'ARRIVE' AND ar.time = cp.od)
           OR
           (ar.type = 'LEAVE' AND ar.time = cp.konec)
       )

       AND ar.ip_address IS NULL
       AND COALESCE(ar.is_break, FALSE) = FALSE
       AND ar.updated_at <= ar.created_at

       AND ar.created_at >=
           COALESCE(pse.started_at, pse.created_at)
           - INTERVAL '1 second'

       AND ar.created_at <=
           COALESCE(pse.finished_at, pse.updated_at)
           + INTERVAL '1 second'
),

skutecne_prescasy AS (
    SELECT
        cp.proces_id,

        CASE
            WHEN odchod.cas IS NOT NULL THEN cp.od
        END AS skutecny_prescas_od,

        odchod.cas AS skutecny_prescas_do

    FROM casy_prescasu cp

    LEFT JOIN LATERAL (
        SELECT
            MAX(ar.time) AS cas

        FROM attendance_records ar

        WHERE ar.person_id = cp.person_id
          AND ar.type = 'LEAVE'
          AND COALESCE(ar.is_break, FALSE) = FALSE

          AND cp.konec > cp.od
          AND ar.time > cp.od

          AND ar.time <
              cp.konec::date + INTERVAL '1 day'

          AND ar.time <= LOCALTIMESTAMP

          AND NOT EXISTS (
              SELECT 1
              FROM automaticke_zaznamy az
              WHERE az.id = ar.id
          )

    ) odchod ON TRUE
),

dny_prescasu AS (
    SELECT DISTINCT
        person_id,
        od::date AS datum

    FROM casy_prescasu

    WHERE od IS NOT NULL
),

sledovane_udalosti AS (
    SELECT
        d.person_id,
        d.datum,
        ar.type,
        ar.time,

        LEAD(ar.type) OVER (
            PARTITION BY
                d.person_id,
                d.datum
            ORDER BY
                ar.time,
                ar.id
        ) AS dalsi_typ,

        LEAD(ar.time) OVER (
            PARTITION BY
                d.person_id,
                d.datum
            ORDER BY
                ar.time,
                ar.id
        ) AS dalsi_cas

    FROM dny_prescasu d

    JOIN attendance_records ar
        ON ar.person_id = d.person_id
       AND ar.time >= d.datum
       AND ar.time < d.datum + INTERVAL '1 day'
       AND ar.is_break = TRUE
       AND ar.time <= LOCALTIMESTAMP
),

sledovane_prestavky_den AS (
    SELECT
        person_id,
        datum,

        FLOOR(
            SUM(
                CASE
                    WHEN type = 'LEAVE'
                     AND dalsi_typ = 'ARRIVE'
                     AND dalsi_cas >= time
                    THEN
                        EXTRACT(
                            EPOCH FROM (dalsi_cas - time)
                        )
                    ELSE 0
                END
            ) / 60.0
        )::bigint AS prestavka_minut,

        BOOL_OR(
            type = 'LEAVE'
            AND (
                dalsi_typ IS DISTINCT FROM 'ARRIVE'
            )
        ) AS chybi_navrat

    FROM sledovane_udalosti

    GROUP BY
        person_id,
        datum
),

delky_prescasu AS (
    SELECT
        sp.proces_id,

        CASE
            WHEN sp.skutecny_prescas_do
                 >= sp.skutecny_prescas_od
            THEN
                FLOOR(
                    EXTRACT(
                        EPOCH FROM (
                            sp.skutecny_prescas_do
                            - sp.skutecny_prescas_od
                        )
                    ) / 60.0
                )::bigint
        END AS celkem_minut,

        COALESCE(
            pd.prestavka_minut,
            0
        ) AS prestavka_minut,

        COALESCE(
            pd.chybi_navrat,
            FALSE
        ) AS chybi_navrat

    FROM skutecne_prescasy sp

    JOIN casy_prescasu cp
        ON cp.proces_id = sp.proces_id

    LEFT JOIN sledovane_prestavky_den pd
        ON pd.person_id = cp.person_id
       AND pd.datum = cp.od::date
)

SELECT
    pe.id::text AS proces_id,

    pe.free_attributes ->> 'overtime_ordered_by'
        AS zadal,

    p.firstname AS jmeno,
    p.lastname AS prijmeni,

    cp.od AS prescas_od,

    cp.konec AS prescas_do,

    sp.skutecny_prescas_od AS skutecny_prescas_od,

    sp.skutecny_prescas_do AS skutecny_prescas_do,

    CASE
        WHEN cp.od IS NOT NULL
         AND NOT d.chybi_navrat
        THEN
            ROUND(
                d.prestavka_minut / 60.0,
                2
            )
    END AS prestavka_hodiny,

    CASE
        WHEN d.celkem_minut IS NOT NULL
         AND NOT d.chybi_navrat
        THEN
            ROUND(
                GREATEST(
                    d.celkem_minut - d.prestavka_minut,
                    0
                ) / 60.0,
                2
            )
    END AS skutecny_prescas_delka,

    CASE
        WHEN d.chybi_navrat THEN
            'Chybí návrat ze sledované přestávky'

        WHEN d.celkem_minut IS NULL THEN
            'Chybí skutečný odchod'

        WHEN d.prestavka_minut > d.celkem_minut THEN
            'Denní sledované přestávky převyšují přesčas'

        ELSE
            'OK'
    END AS kontrola_dochazky,

    pe.free_attributes ->> 'batch_number' AS davka,

    b.id AS id_davky,

    'https://company.com/ui/batch/'
        || b.id::text AS davka_url,

    COALESCE(
        stroje.vyrobni_cisla,
        NULLIF(
            BTRIM(
                pe.free_attributes
                ->> 'machine_serial_number'
            ),
            ''
        )
    ) AS seriove_cislo_stroje,

    objednavky.cisla_objednavek
        AS prodejni_objednavka,

    CASE
        WHEN objednavky.pocet = 1 THEN
            'https://company.com/ui/sales-order/'
            || objednavky.jedina_objednavka::text
    END AS prodejni_objednavka_url,

    COALESCE(
        NULLIF(ev.label ->> '2', ''),
        NULLIF(ev.label ->> 'cs', ''),
        pe.free_attributes ->> 'overtime_reason'
    ) AS duvod

FROM prescasy pe

LEFT JOIN casy_prescasu cp
    ON cp.proces_id = pe.id

LEFT JOIN skutecne_prescasy sp
    ON sp.proces_id = pe.id

LEFT JOIN delky_prescasu d
    ON d.proces_id = pe.id

LEFT JOIN people p
    ON p.id = pe.entity_id

LEFT JOIN enum_values ev
    ON ev.enum_id = 'overtime_reason'
   AND ev.code =
       pe.free_attributes ->> 'overtime_reason'

LEFT JOIN batches b
    ON b.id = pe.nalezene_id_davky

LEFT JOIN souhrn_objednavek objednavky
    ON objednavky.vychozi_id = b.id

LEFT JOIN souhrn_stroju stroje
    ON stroje.vychozi_id = b.id

ORDER BY
    pe.created_at DESC,
    pe.id DESC
