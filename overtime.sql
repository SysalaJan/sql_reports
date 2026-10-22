WITH RECURSIVE
prescasy AS (
    SELECT
        pe.*,
        nalezena_davka.id AS nalezene_id_davky

    FROM process_executions pe

    LEFT JOIN LATERAL (
        SELECT MIN(bx.id) AS id
        FROM batches bx
        WHERE bx.production_batch = TRUE
          AND bx.number = BTRIM(
              pe.free_attributes ->> 'batch_number'
          )
        HAVING COUNT(*) = 1
    ) nalezena_davka ON TRUE

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
)

SELECT
    pe.id::text AS proces_id,

    pe.free_attributes ->> 'overtime_ordered_by' AS zadal,

    p.firstname AS jmeno,
    p.lastname AS prijmeni,

    TO_CHAR(
        NULLIF(
            pe.free_attributes ->> 'overtime_from',
            ''
        )::timestamp,
        'DD.MM.YYYY HH24:MI'
    ) AS prescas_od,

    TO_CHAR(
        NULLIF(
            pe.free_attributes ->> 'overtime_to',
            ''
        )::timestamp,
        'DD.MM.YYYY HH24:MI'
    ) AS prescas_do,

    pe.free_attributes ->> 'batch_number' AS davka,

    b.id AS id_davky,

    'https://company.com/ui/batch/'
        || b.id::text AS davka_url,

    COALESCE(
        stroje.vyrobni_cisla,
        NULLIF(
            BTRIM(pe.free_attributes ->> 'machine_serial_number'),
            ''
        )
    ) AS seriove_cislo_stroje,

    objednavky.cisla_objednavek AS prodejni_objednavka,

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

LEFT JOIN people p
    ON p.id = pe.entity_id

LEFT JOIN enum_values ev
    ON ev.enum_id = 'overtime_reason'
   AND ev.code = pe.free_attributes ->> 'overtime_reason'

LEFT JOIN batches b
    ON b.id = pe.nalezene_id_davky

LEFT JOIN souhrn_objednavek objednavky
    ON objednavky.vychozi_id = b.id

LEFT JOIN souhrn_stroju stroje
    ON stroje.vychozi_id = b.id

ORDER BY
    pe.created_at DESC,
    pe.id DESC
