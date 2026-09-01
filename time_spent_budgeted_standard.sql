WITH evidence AS (
    SELECT
        bwe.*,

        SUM(COALESCE(bwe.standard_time_minutes, 0)) OVER (
            PARTITION BY bwe.batch_id, bwe.stage_id
        ) AS total_stage_norm

    FROM batch_work_evidence bwe
    WHERE bwe.deleted = false
)

SELECT 
    bwe.id AS batch,
    p.firstname AS jmeno,
    p.lastname AS prijmeni,
    bwe.started_at AS start_time,
    bwe.finished_at AS end_time,
    b.finished_at AS real_batch_end_time,

    ROUND(
        (
            EXTRACT(EPOCH FROM (
                COALESCE(bwe.finished_at, NOW()) - bwe.started_at
            )) / 60
        )::numeric,
        1
    ) AS duration,

    ROUND(
        (
            CASE
                WHEN bwe.count > 0
                    THEN bwe.total_stage_norm
                ELSE 0
            END
        )::numeric,
        1
    ) AS norm_time,

    COALESCE(
        stg.name->>'2',
        stg.name->>'cz',
        st.shortcut,
        'Ostatní'
    ) AS workplace,

    bwe.count AS quantity,

    CONCAT(
        b.number,
        ' ',
        g.code,
        ' ',
        COALESCE(
            g.name->>'2',
            g.name->>'cz',
            g.name->>'1',
            g.name::text
        )
    ) AS davka,

    CONCAT(
        'https://factorify.pbt-works.com/ui/batch/',
        b.number
    ) AS batch_url,

    ROUND(
        (
            EXTRACT(EPOCH FROM (
                COALESCE(bwe.finished_at, NOW()) - bwe.started_at
            )) / 60
            -
            CASE
                WHEN bwe.count > 0
                    THEN bwe.total_stage_norm
                ELSE 0
            END
        )::numeric,
        1
    ) AS diff_time

FROM evidence bwe

LEFT JOIN people p
    ON bwe.person_id = p.id

LEFT JOIN stages st
    ON bwe.stage_id = st.id

LEFT JOIN stage_groups stg
    ON st.stage_group_id = stg.id

LEFT JOIN batches b
    ON bwe.batch_id = b.id

LEFT JOIN goods g
    ON b.goods_id = g.id

WHERE bwe.started_at IS NOT NULL
  AND bwe.started_at <= NOW()
  AND bwe.started_at > NOW() - INTERVAL '30 days'

ORDER BY bwe.started_at DESC;
