WITH RECURSIVE

evidence AS (
    SELECT
        wr.id,
        wr.person_id,
        wr.batch_id,
        wr.stage_id,
        wr.workflow_operation_id,
        wr.started_at,
        wr.finished_at,
        wr.quantity AS count,
        wr.worker_minutes AS duration_minutes,
        wr.effectiveness_standard_time_minutes AS standard_time_minutes
    FROM work_records wr
    WHERE wr.deleted = false
      AND wr.person_id IS NOT NULL
      AND wr.batch_id IS NOT NULL
      AND wr.delivery_bill_id IS NULL
      AND wr.delivery_bill_package_id IS NULL
      AND wr.started_at IS NOT NULL
      AND wr.started_at <= NOW()
      AND wr.started_at > NOW() - INTERVAL '100 days'
),

report_batches AS (
    SELECT DISTINCT batch_id
    FROM evidence
    WHERE batch_id IS NOT NULL
),

batch_info AS (
    SELECT
        b.id AS batch_id,
        b.goods_id,
        b.created_at,
        b.sales_order_item_id,
        b.consuming_sales_order_ids,
        b.root_batch_id,
        b.repairing_batch_id,
        soi.sales_order_id AS direct_sales_order_id
    FROM batches b
    JOIN report_batches rb
        ON rb.batch_id = b.id
    LEFT JOIN sales_order_items soi
        ON soi.id = b.sales_order_item_id
       AND soi.deleted = false
),

batch_tree AS (
    SELECT
        rb.batch_id AS source_batch_id,
        rb.batch_id AS current_batch_id,
        0 AS depth,
        ARRAY[rb.batch_id]::bigint[] AS path,
        'Přímá dávka'::text AS relation_path
    FROM report_batches rb

    UNION ALL

    SELECT
        bt.source_batch_id,
        rel.next_batch_id,
        bt.depth + 1,
        bt.path || rel.next_batch_id,
        bt.relation_path || ' -> ' || rel.relation_type
    FROM batch_tree bt
    JOIN LATERAL (

        SELECT
            ube.using_batch_id AS next_batch_id,
            'nadřazená dávka'::text AS relation_type
        FROM used_batches_evidence ube
        WHERE ube.used_batch_id = bt.current_batch_id
          AND ube.deleted = false
          AND ube.using_batch_id IS NOT NULL

        UNION ALL

        SELECT
            b.repairing_batch_id,
            'opravovaná dávka'
        FROM batches b
        WHERE b.id = bt.current_batch_id
          AND b.repairing_batch_id IS NOT NULL

        UNION ALL

        SELECT
            bre.batch_id,
            'oprava evidence'
        FROM batch_repairs_evidence bre
        WHERE bre.repair_batch_id = bt.current_batch_id
          AND bre.batch_id IS NOT NULL

        UNION ALL

        SELECT
            b.root_batch_id,
            'root dávka'
        FROM batches b
        WHERE b.id = bt.current_batch_id
          AND b.root_batch_id IS NOT NULL

    ) rel ON TRUE
    WHERE bt.depth < 20
      AND NOT rel.next_batch_id = ANY(bt.path)
),

batch_candidates AS (

    SELECT
        bt.source_batch_id,
        soi.sales_order_id,
        bt.current_batch_id AS linked_batch_id,
        bt.depth,
        CASE WHEN bt.depth = 0 THEN 1 ELSE 2 END AS priority,
        CASE
            WHEN bt.depth = 0 THEN 'Přímá vazba'
            ELSE 'Výrobní návaznost'
        END AS assignment_type
    FROM batch_tree bt
    JOIN batches b
        ON b.id = bt.current_batch_id
    JOIN sales_order_items soi
        ON soi.id = b.sales_order_item_id
       AND soi.deleted = false
    WHERE soi.sales_order_id IS NOT NULL

    UNION ALL

    SELECT
        bt.source_batch_id,
        x.sales_order_id,
        bt.current_batch_id,
        bt.depth,
        3,
        'Výrobní návaznost'
    FROM batch_tree bt
    JOIN batches b
        ON b.id = bt.current_batch_id
    CROSS JOIN LATERAL (
        SELECT unnest(b.consuming_sales_order_ids) AS sales_order_id
    ) x
    WHERE b.consuming_sales_order_ids IS NOT NULL
),

planning_tree AS (

    SELECT
        rb.batch_id AS source_batch_id,
        sdm.used_supply_id AS current_supply_id,
        sdm.is_batch,
        sdm.goods_id,
        sdm.demand_id,
        sdm.using_supply_id,
        sdm.using_operation_id,
        0 AS depth,
        ARRAY[sdm.used_supply_id]::bigint[] AS path
    FROM report_batches rb
    JOIN planning_output.supply_demand_matches sdm
        ON sdm.used_supply_id = rb.batch_id
       AND sdm.is_batch = true

    UNION ALL

    SELECT
        pt.source_batch_id,
        sdm.used_supply_id,
        sdm.is_batch,
        sdm.goods_id,
        sdm.demand_id,
        sdm.using_supply_id,
        sdm.using_operation_id,
        pt.depth + 1,
        pt.path || sdm.used_supply_id
    FROM planning_tree pt
    JOIN planning_output.supply_demand_matches sdm
        ON sdm.used_supply_id = pt.using_supply_id
    WHERE pt.demand_id IS NULL
      AND pt.using_supply_id IS NOT NULL
      AND pt.depth < 30
      AND NOT sdm.used_supply_id = ANY(pt.path)
),

planning_candidates AS (
    SELECT
        pt.source_batch_id,
        soi.sales_order_id,
        CASE
            WHEN pt.current_supply_id > 0 THEN pt.current_supply_id
            ELSE NULL
        END AS linked_batch_id,
        pt.depth,
        4 AS priority,
        'Plánování'::text AS assignment_type
    FROM planning_tree pt
    JOIN sales_order_items soi
        ON soi.id = pt.demand_id
       AND soi.deleted = false
    WHERE pt.demand_id IS NOT NULL
      AND soi.sales_order_id IS NOT NULL
),

goods_tree AS (
    SELECT
        bi.batch_id AS source_batch_id,
        bi.goods_id AS current_goods_id,
        bi.created_at AS source_batch_created_at,
        0 AS depth,
        ARRAY[bi.goods_id]::bigint[] AS path
    FROM batch_info bi
    WHERE bi.goods_id IS NOT NULL

    UNION ALL

    SELECT
        gt.source_batch_id,
        bom.goods_id,
        gt.source_batch_created_at,
        gt.depth + 1,
        gt.path || bom.goods_id
    FROM goods_tree gt
    JOIN bill_of_material_items bom
        ON bom.part_goods_id = gt.current_goods_id
       AND COALESCE(bom.ignored, false) = false
    WHERE gt.depth < 20
      AND NOT bom.goods_id = ANY(gt.path)
),

operation_goods_tree AS (
    SELECT
        bi.batch_id AS source_batch_id,
        bi.goods_id AS current_goods_id,
        bi.created_at AS source_batch_created_at,
        0 AS depth,
        ARRAY[bi.goods_id]::bigint[] AS path
    FROM batch_info bi
    WHERE bi.goods_id IS NOT NULL

    UNION ALL

    SELECT DISTINCT
        ogt.source_batch_id,
        parent_g.id,
        ogt.source_batch_created_at,
        ogt.depth + 1,
        ogt.path || parent_g.id
    FROM operation_goods_tree ogt
    JOIN operation_bill_of_material_items obomi
        ON obomi.goods_id = ogt.current_goods_id
    JOIN workflow_operations wo
        ON wo.id = obomi.workflow_operation_id
       AND COALESCE(wo.deleted, false) = false
    JOIN goods parent_g
        ON parent_g.workflow_id = wo.workflow_id
    WHERE ogt.depth < 20
      AND NOT parent_g.id = ANY(ogt.path)
),

goods_plan_candidates AS (
    SELECT DISTINCT
        gt.source_batch_id,
        gt.depth,
        so.id AS sales_order_id,
        so.created_at AS sales_order_created_at
    FROM goods_tree gt
    JOIN goods g
        ON g.id = gt.current_goods_id
    JOIN sales_orders so
        ON so.free_attributes ->> 'PLAN_NO' IS NOT NULL
    WHERE jsonb_typeof(g.free_attributes -> 'PLAN') = 'array'
      AND g.free_attributes -> 'PLAN'
          @> to_jsonb(so.free_attributes ->> 'PLAN_NO')
),

plan_candidates AS (
    SELECT
        gpc.source_batch_id,
        gpc.sales_order_id,
        NULL::bigint AS linked_batch_id,
        gpc.depth,
        5 AS priority,
        'Kusovník + plán'::text AS assignment_type,
        gpc.sales_order_created_at
    FROM goods_plan_candidates gpc
),

operation_candidates_raw AS (
    SELECT
        ogt.source_batch_id,
        ogt.depth,

        pb.id AS linked_batch_id,
        soi.sales_order_id,

        ABS(
            EXTRACT(
                EPOCH FROM (
                    pb.created_at - ogt.source_batch_created_at
                )
            )
        ) / 86400.0 AS days_difference

    FROM operation_goods_tree ogt

    JOIN batches pb
        ON pb.goods_id = ogt.current_goods_id
       AND pb.created_at BETWEEN
            ogt.source_batch_created_at - INTERVAL '180 days'
            AND
            ogt.source_batch_created_at + INTERVAL '180 days'

    JOIN sales_order_items soi
        ON soi.id = pb.sales_order_item_id
       AND soi.deleted = false

    WHERE soi.sales_order_id IS NOT NULL
),

operation_candidates AS (
    SELECT DISTINCT ON (ocr.source_batch_id)

        ocr.source_batch_id,
        ocr.sales_order_id,
        ocr.linked_batch_id,
        ocr.depth,
        6 AS priority,
        'Odhad podle kusovníku a času'::text AS assignment_type,
        ocr.days_difference

    FROM operation_candidates_raw ocr

    ORDER BY
        ocr.source_batch_id,
        ocr.depth ASC,
        ocr.days_difference ASC,
        ocr.sales_order_id DESC
),

all_candidates AS (

    SELECT
        bc.source_batch_id,
        bc.sales_order_id,
        bc.linked_batch_id,
        bc.depth,
        bc.priority,
        bc.assignment_type,
        NULL::double precision AS days_difference,
        NULL::timestamp AS sales_order_created_at
    FROM batch_candidates bc

    UNION ALL

    SELECT
        pc.source_batch_id,
        pc.sales_order_id,
        pc.linked_batch_id,
        pc.depth,
        pc.priority,
        pc.assignment_type,
        NULL::double precision,
        NULL::timestamp
    FROM planning_candidates pc

    UNION ALL

    SELECT
        pc.source_batch_id,
        pc.sales_order_id,
        pc.linked_batch_id,
        pc.depth,
        pc.priority,
        pc.assignment_type,
        NULL::double precision,
        pc.sales_order_created_at
    FROM plan_candidates pc

    UNION ALL

    SELECT
        oc.source_batch_id,
        oc.sales_order_id,
        oc.linked_batch_id,
        oc.depth,
        oc.priority,
        oc.assignment_type,
        oc.days_difference,
        NULL::timestamp
    FROM operation_candidates oc
),

best_sales_order AS (
    SELECT DISTINCT ON (ac.source_batch_id)

        ac.source_batch_id,
        ac.sales_order_id,
        ac.linked_batch_id,
        ac.depth,
        ac.assignment_type,
        ac.days_difference

    FROM all_candidates ac

    JOIN batches sb
        ON sb.id = ac.source_batch_id

    JOIN sales_orders so
        ON so.id = ac.sales_order_id

    ORDER BY
        ac.source_batch_id,

        ac.priority ASC,

        ac.depth ASC,

        COALESCE(ac.days_difference, 0) ASC,

        ABS(
            EXTRACT(
                EPOCH FROM (
                    COALESCE(
                        ac.sales_order_created_at,
                        sb.created_at
                    )
                    - sb.created_at
                )
            )
        ) ASC,

        ac.sales_order_id DESC
)

SELECT

    bwe.id AS id,

    p.lastname AS prijmeni,
    p.firstname AS jmeno,

    COALESCE(
        stg.name ->> '2',
        stg.name ->> 'cz',
        st.shortcut,
        'Ostatní'
    ) AS workplace,
    so.id AS sales_order_id,
    COALESCE(
        NULLIF(
            so.free_attributes ->> 'MACHINE_TYPE_TEXT',
            ''
        ),
        NULLIF(
            so.free_attributes ->> 'JIRA_MACHINE_TYPE',
            ''
        )
    ) AS machine_type,
    COALESCE(
        NULLIF(
            bsn.serial_number,
            ''
        ),
        NULLIF(
            so.free_attributes ->> 'MACHINE_NO',
            ''
        )
    ) AS serial_number,
    bso.assignment_type,
    bso.depth AS assignment_depth,
    bso.linked_batch_id,
    ROUND(
        bso.days_difference::numeric,
        1
    ) AS assignment_days_difference,

    bwe.started_at AS start_time,
    bwe.finished_at AS end_time,
    b.finished_at AS real_batch_end_time,
    ROUND(bwe.duration_minutes::numeric, 1) AS duration,

    ROUND(bwe.standard_time_minutes::numeric, 1) AS norm_time,

    ROUND(
        (bwe.duration_minutes - bwe.standard_time_minutes)::numeric,
        1
    ) AS diff_time,

    bwe.count AS quantity,

    CONCAT(
        'https://company.com/ui/batch/',
        b.number
    ) AS batch_url,

    CONCAT(
        b.number,
        ' ',
        g.code,
        ' ',
        COALESCE(
            g.name ->> '2',
            g.name ->> 'cz',
            g.name ->> '1',
            g.name::text
        )
    ) AS davka

FROM evidence bwe

LEFT JOIN people p
    ON p.id = bwe.person_id

LEFT JOIN stages st
    ON st.id = bwe.stage_id

LEFT JOIN stage_groups stg
    ON stg.id = st.stage_group_id

LEFT JOIN batches b
    ON b.id = bwe.batch_id

LEFT JOIN goods g
    ON g.id = b.goods_id

LEFT JOIN best_sales_order bso
    ON bso.source_batch_id = b.id

LEFT JOIN sales_orders so
    ON so.id = bso.sales_order_id

LEFT JOIN batch_serial_numbers bsn
    ON bsn.id =
        CASE
            WHEN NULLIF(
                so.free_attributes ->> 'SN',
                ''
            ) IS NOT NULL
            THEN (
                so.free_attributes ->> 'SN'
            )::bigint
            ELSE NULL
        END

ORDER BY bwe.started_at DESC
