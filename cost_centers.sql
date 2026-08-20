SELECT 
    ad.document_number AS cislo_dokladu,
    ad.received_document_number AS variabilni_symbol,
    adt.name->>'2' AS typ_dokladu,
    COALESCE(addr.name, c.name, 'Neznámý dodavatel') AS dodavatel,
    
    (cc.code || '  ' || REGEXP_REPLACE(cc.name->>'2', '^[0-9]+\s*[\-\–\—]?\s*', '')) AS stredisko_nazev,
    
    a.number AS polozka_ucet,
    a.name->>'2' AS polozka_nazev,
    
    am.time::date AS datum_uctovani,
    ad.issue_date AS datum_vystaveni,
    ad.due_date AS datum_splatnosti,
    
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
-- Opravená vazba na dodavatele přes addresses
LEFT JOIN 
    public.addresses addr ON ad.address_id = addr.id
LEFT JOIN 
    public.companies c ON addr.company_id = c.id
LEFT JOIN 
    public.cost_centers cc ON am.cost_center_id = cc.id
WHERE 
    a.number LIKE '5%'
    AND am.deleted = FALSE
    AND ad.deleted = FALSE
    AND am.debit_amount > 0
    AND (
        cc.code IN ('510', '512', '515', '520', '530', '536', '540', '550', '553', '560', '570')
        OR cc.name->>'2' ILIKE '%Montáž%' 
        OR cc.name->>'2' ILIKE '%Elektromontáž%' 
        OR cc.name->>'2' ILIKE '%Předvýroba%' 
        OR cc.name->>'2' ILIKE '%Výroba%' 
        OR cc.name->>'2' ILIKE '%Konstrukce%' 
        OR cc.name->>'2' ILIKE '%Servis%' 
        OR cc.name->>'2' ILIKE '%Obchod%' 
        OR cc.name->>'2' ILIKE '%Ekonomika%' 
        OR cc.name->>'2' ILIKE '%Provoz%' 
        OR cc.name->>'2' ILIKE '%Vedení%' 
        OR cc.name->>'2' ILIKE '%IT%'
    )
    AND adt.name->>'2' NOT ILIKE '%interní%'
    AND a.number NOT LIKE '521%' 
    AND a.number NOT LIKE '524%' 
    AND a.number NOT LIKE '527%' 
    AND a.number NOT LIKE '551%' 
    AND a.number NOT LIKE '563%' 
    AND am.time >= '2026-01-01' 
    AND am.time <= '2026-12-31'
ORDER BY 
    stredisko_nazev, 
    datum_uctovani,
    cislo_dokladu;
