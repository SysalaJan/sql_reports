SELECT 
    (cc.code || '  ' || REGEXP_REPLACE(cc.name->>'2', '^[0-9]+\s*[\-\–\—]?\s*', '')) AS stredisko_nazev,
    
    a.number AS polozka_ucet,
    a.name->>'2' AS polozka_nazev,
    
    adt.name->>'2' AS typ_dokladu,
    ad.document_number AS cislo_dokladu,
    c.name AS dodavatel,
    am.time::date AS datum_uctovani,
    
    am.text->>'2' AS detail_polozky,
    am.debit_amount AS castka_bez_dph
FROM 
    public.accounting_moves_v am
JOIN 
    public.accounts a ON am.account_id = a.id
JOIN 
    public.accounting_documents ad ON am.accounting_document_id = ad.id
JOIN 
    public.accounting_document_types adt ON ad.accounting_document_type_id = adt.id
LEFT JOIN 
    public.cost_centers cc ON am.cost_center_id = cc.id
LEFT JOIN 
    public.companies c ON ad.address_id = c.id
WHERE 
    a.number LIKE '5%'
    AND am.deleted = FALSE
    AND ad.deleted = FALSE
    AND am.debit_amount > 0
    
    AND (
        cc.code IN ('510', '512', '515', '520', '530', '536', '540', '550', '553', '560', '570')
        OR cc.name->>'2' ILIKE '%Středisko A%' -- 560
        OR cc.name->>'2' ILIKE '%Středisko B%' -- 570
        OR cc.name->>'2' ILIKE '%Středisko C%' -- 553
        OR cc.name->>'2' ILIKE '%Středisko D%' -- 550
        OR cc.name->>'2' ILIKE '%Středisko E%' -- 540
        OR cc.name->>'2' ILIKE '%Středisko F%' -- 536
        OR cc.name->>'2' ILIKE '%Středisko G%' -- 530
        OR cc.name->>'2' ILIKE '%Středisko H%' -- 520
        OR cc.name->>'2' ILIKE '%Středisko I%' -- 515
        OR cc.name->>'2' ILIKE '%Středisko J%' -- 510
        OR cc.name->>'2' ILIKE '%Středisko K%' -- 512
    )
    -- bez 802 Dotace a 600 Budova

    AND adt.name->>'2' NOT ILIKE '%interní%'
    
    AND a.number NOT LIKE '521%' -- Mzdy
    AND a.number NOT LIKE '524%' -- Sociální a zdravotní pojištění
    AND a.number NOT LIKE '527%' -- Stravenky a sociální náklady
    AND a.number NOT LIKE '551%' -- Odpisy majetku
    AND a.number NOT LIKE '563%' -- Kurzové ztráty
    
    AND am.time >= '2026-01-01' AND am.time <= '2026-12-31'
ORDER BY 
    stredisko_nazev, 
    datum_uctovani,
    cislo_dokladu;
