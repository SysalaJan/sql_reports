SELECT 
    bwe.id AS batch,
    p.firstname AS jmeno,
    p.lastname AS prijmeni,
    bwe.started_at AS start_time,
    bwe.finished_at AS end_time,
    ROUND((EXTRACT(EPOCH FROM (bwe.finished_at - bwe.started_at)) / 60)::numeric, 1) AS duration,
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
        SUBSTRING(g.name::text FROM 8 FOR POSITION('"' IN SUBSTRING(g.name::text FROM 8)) - 1)
    ) AS davka, 
    
    CONCAT('https://factorify.pbt-works.com/ui/batch/', b.number) AS link_batch,
    
    ROUND(((EXTRACT(EPOCH FROM (bwe.finished_at - bwe.started_at)) / 60) - (bwe.standard_time_minutes / NULLIF(bwe.batch_quantity, 0) * bwe.count))::numeric, 1) AS diff_time
FROM batch_work_evidence bwe
LEFT JOIN people p ON bwe.person_id = p.id
LEFT JOIN stages st ON bwe.stage_id = st.id
LEFT JOIN stage_groups stg ON st.stage_group_id = stg.id
LEFT JOIN batches b ON bwe.batch_id = b.id 
LEFT JOIN goods g ON b.goods_id = g.id
WHERE bwe.deleted = false
  AND bwe.started_at <= NOW()
  AND bwe.started_at > NOW() - make_interval(days => 30)
ORDER BY bwe.started_at DESC
