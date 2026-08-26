WITH platne_transfery AS (
    SELECT
        sm.id,
        sm.stock_document_id,
        sm.stock_id,
        sm.goods_id,
        sm.batch_id,
        sm.reserving_batch_id,
        NULLIF(BTRIM(sm.position), '') AS pozice,
        sm.quantity,
        sm.moved_at
    FROM public.stock_moves AS sm
    JOIN public.stock_documents AS sd
        ON sd.id = sm.stock_document_id
    WHERE sd.type = 'TRANSFER'
      AND sm.quantity <> 0
      AND NULLIF(BTRIM(sm.position), '') IS NOT NULL
      AND sm.cancelled_stock_move_id IS NULL
      AND COALESCE(sm.cancelled_quantity, 0) = 0
      AND NOT EXISTS (
          SELECT 1
          FROM public.stock_moves AS storno
          WHERE storno.cancelled_stock_move_id = sm.id
      )
      AND sm.moved_at >= TIMESTAMP '2025-01-01 00:00:00'
      AND sm.moved_at <  TIMESTAMP '2027-01-01 00:00:00'
),

skupiny_transferu AS (
    SELECT
        stock_document_id,
        stock_id,
        goods_id,
        batch_id,
        reserving_batch_id,

        MIN(moved_at) AS datum_presunu,

        COUNT(*) FILTER (
            WHERE quantity < 0
        ) AS pocet_odchozich_pohybu,

        COUNT(*) FILTER (
            WHERE quantity > 0
        ) AS pocet_prichozich_pohybu,

        COUNT(DISTINCT pozice) AS pocet_pozic,

        SUM(quantity) AS rozdil_mnozstvi

    FROM platne_transfery

    GROUP BY
        stock_document_id,
        stock_id,
        goods_id,
        batch_id,
        reserving_batch_id

    HAVING COUNT(*) FILTER (WHERE quantity < 0) > 0
       AND COUNT(*) FILTER (WHERE quantity > 0) > 0
       AND COUNT(DISTINCT pozice) > 1
       AND ABS(SUM(quantity)) < 0.000001
)

SELECT
    EXTRACT(YEAR FROM datum_presunu)::integer AS rok,

    CASE
        WHEN GROUPING(DATE_TRUNC('month', datum_presunu)) = 1
            THEN 'CELKEM ZA ROK'
        ELSE TO_CHAR(
            DATE_TRUNC('month', datum_presunu),
            'YYYY-MM'
        )
    END AS mesic,

    SUM(pocet_odchozich_pohybu)
        AS pocet_skladovych_pohybu_mezi_pozicemi,

    COUNT(DISTINCT stock_document_id)
        AS pocet_presunovych_dokladu,

    COUNT(*)
        AS pocet_presunutych_polozek

FROM skupiny_transferu

GROUP BY GROUPING SETS (
    (
        EXTRACT(YEAR FROM datum_presunu),
        DATE_TRUNC('month', datum_presunu)
    ),
    (
        EXTRACT(YEAR FROM datum_presunu)
    )
)

ORDER BY
    EXTRACT(YEAR FROM datum_presunu),
    DATE_TRUNC('month', datum_presunu) NULLS LAST;
