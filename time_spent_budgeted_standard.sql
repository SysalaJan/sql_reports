SELECT 
    bwe.id AS batch,
    p.firstname AS jmeno,
    p.lastname AS prijmeni,
    bwe.started_at AS start_time,
    bwe.finished_at AS end_time,
    b.finished_at AS real_batch_end_time,

    ROUND((EXTRACT(EPOCH FROM (COALESCE(bwe.finished_at, NOW()) - bwe.started_at)) / 60)::numeric, 1) AS duration,
    ROUND((bwe.standard_time_minutes / NULLIF(bwe.batch_quantity, 0) * bwe.count)::numeric, 1) AS norm_time,
    
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
        CASE 
            WHEN g.name::text LIKE '%"%"%' THEN SPLIT_PART(g.name::text, '"', 2)
            ELSE g.name::text
        END
    ) AS davka, 
    
    CONCAT('https://pbt-works.com', b.number) AS batch_url,
    
    ROUND(((EXTRACT(EPOCH FROM (COALESCE(bwe.finished_at, NOW()) - bwe.started_at)) / 60) - (bwe.standard_time_minutes / NULLIF(bwe.batch_quantity, 0) * bwe.count))::numeric, 1) AS diff_time
FROM batch_work_evidence bwe
LEFT JOIN people p ON bwe.person_id = p.id
LEFT JOIN stages st ON bwe.stage_id = st.id
LEFT JOIN stage_groups stg ON st.stage_group_id = stg.id
LEFT JOIN batches b ON bwe.batch_id = b.id 
LEFT JOIN goods g ON b.goods_id = g.id
WHERE bwe.deleted = false
  AND bwe.started_at <= NOW()
  AND bwe.started_at > NOW() - INTERVAL '30 days'
ORDER BY bwe.started_at DESC;
