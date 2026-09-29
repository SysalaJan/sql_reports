WITH
/* Pro jiný rok změň pouze tuto hodnotu. */
parametry AS (
    SELECT 2026::integer AS rok
),

strediska AS (
    SELECT
        cc.id,
        BTRIM(cc.code) AS kod,
        BTRIM(cc.code) || '  ' ||
        COALESCE(
            REGEXP_REPLACE(
                cc.name->>'2',
                '^[0-9]+\s*[\-–—]?\s*',
                ''
            ),
            ''
        ) AS nazev
    FROM public.cost_centers cc
    WHERE
        cc.code IN (
            '510', '512', '515', '520', '530', '536',
            '540', '550', '553', '560', '570'
        )
        OR cc.name->>'2' ILIKE ANY (ARRAY[
            '%Montáž%', '%Elektromontáž%', '%Předvýroba%',
            '%Výroba%', '%Konstrukce%', '%Servis%', '%Obchod%',
            '%Ekonomika%', '%Provoz%', '%Vedení%', '%IT%'
        ])
),

ucty AS (
    SELECT
        a.id,
        a.number,
        a.name->>'2' AS nazev,
        a.free_attributes,
        CASE
            WHEN a.number LIKE '52%' THEN 'Mzdy'
            WHEN a.number IN ('648200', '346100') THEN 'Dotace'
            ELSE 'Ostatní náklady'
        END AS kategorie
    FROM public.accounts a
    WHERE
        a.number LIKE '5%'
        OR a.number IN ('648200', '346100')
),

/* Rozpočet pro kombinaci účet + středisko + rok.
   Prázdné pole = NULL, vyplněná nula = nulový rozpočet. */
rozpocty AS (
    SELECT
        p.rok,
        s.id AS stredisko_id,
        s.kod AS stredisko_kod,
        s.nazev AS stredisko_nazev,
        u.id AS ucet_id,
        u.number AS polozka_ucet,
        u.nazev AS polozka_nazev,
        u.kategorie,

        NULLIF(
            BTRIM(
                u.free_attributes ->>
                ('rozpocet_' || p.rok::text || '_' || s.kod)
            ),
            ''
        )::numeric AS rozpocet_czk

    FROM parametry p
    CROSS JOIN strediska s
    CROSS JOIN ucty u
),

/* Všechny zaúčtované pohyby vybraných účtů,
   včetně interních a pohybů bez účetního dokladu.
   MD - Dal zohlední i snížení nákladů a opravy.

   Na účtu 648200 bude běžný výnos záporný.
   Účet 346100 zůstává samostatným řádkem pohybu dotace. */
pohyby AS (
    SELECT
        am.cost_center_id AS stredisko_id,
        am.account_id AS ucet_id,

        COALESCE(am.debit_amount, 0)
            - COALESCE(am.credit_amount, 0) AS castka_czk,

        eur.rate AS kurz_eur

    FROM public.accounting_moves_v am

    JOIN strediska s
        ON s.id = am.cost_center_id

    JOIN ucty u
        ON u.id = am.account_id

    CROSS JOIN parametry p

    LEFT JOIN LATERAL (
        SELECT
            COALESCE(
                NULLIF(cr.imported_rate, 0),
                NULLIF(cr.fixed_rate, 0)
            )::numeric AS rate

        FROM public.currency_rates cr

        WHERE
            cr.currency_id = 'EUR'
            AND cr.valid_from <= am.time
            AND (
                cr.valid_to IS NULL
                OR cr.valid_to > am.time
            )

        ORDER BY cr.valid_from DESC
        LIMIT 1
    ) eur ON TRUE

    WHERE
        am.deleted = FALSE
        AND am.time >= MAKE_DATE(p.rok, 1, 1)
        AND am.time < MAKE_DATE(p.rok + 1, 1, 1)
),

cerpani AS (
    SELECT
        stredisko_id,
        ucet_id,
        COUNT(*) AS pocet_pohybu,
        SUM(castka_czk) AS vycerpano_czk,

        /* Při chybějícím kurzu nevracíme neúplný součet EUR. */
        CASE
            WHEN COUNT(*) FILTER (
                WHERE castka_czk <> 0
                  AND kurz_eur IS NULL
            ) > 0
                THEN NULL::numeric

            ELSE SUM(
                CASE
                    WHEN castka_czk = 0 THEN 0::numeric
                    ELSE castka_czk / kurz_eur
                END
            )
        END AS vycerpano_eur,

        COUNT(*) FILTER (
            WHERE castka_czk <> 0
              AND kurz_eur IS NULL
        ) AS pocet_pohybu_bez_kurzu

    FROM pohyby

    GROUP BY
        stredisko_id,
        ucet_id
)

SELECT
    r.rok,
    r.stredisko_kod,
    r.stredisko_nazev,
    r.polozka_ucet,
    r.polozka_nazev,
    r.kategorie,

    ROUND(r.rozpocet_czk, 2) AS rozpocet_czk,

    ROUND(
        COALESCE(c.vycerpano_czk, 0),
        2
    ) AS vycerpano_czk,

    ROUND(
        r.rozpocet_czk - COALESCE(c.vycerpano_czk, 0),
        2
    ) AS zbyva_czk,

    ROUND(
        100.0 * COALESCE(c.vycerpano_czk, 0)
        / NULLIF(r.rozpocet_czk, 0),
        2
    ) AS cerpani_procent,

    CASE
        WHEN r.rozpocet_czk IS NULL
            THEN 'Nenastaveno'

        WHEN COALESCE(c.vycerpano_czk, 0) > r.rozpocet_czk
            THEN 'Překročeno'

        WHEN COALESCE(c.vycerpano_czk, 0) = r.rozpocet_czk
            THEN 'Vyčerpáno'

        ELSE 'V rámci rozpočtu'
    END AS stav_rozpoctu,

    ROUND(
        CASE
            WHEN c.pocet_pohybu IS NULL THEN 0::numeric
            ELSE c.vycerpano_eur
        END,
        2
    ) AS vycerpano_eur,

    COALESCE(c.pocet_pohybu, 0) AS pocet_pohybu,

    COALESCE(
        c.pocet_pohybu_bez_kurzu,
        0
    ) AS pocet_pohybu_bez_kurzu

FROM rozpocty r

LEFT JOIN cerpani c
    ON c.stredisko_id = r.stredisko_id
    AND c.ucet_id = r.ucet_id

/* Zobrazíme i rozpočet bez pohybů a pohyby bez rozpočtu. */
WHERE
    r.rozpocet_czk IS NOT NULL
    OR c.pocet_pohybu > 0

ORDER BY
    r.stredisko_kod,
    r.polozka_ucet;
