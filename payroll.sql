SELECT 
    p.firstname AS jmeno,
    p.lastname AS prijmeni,
    pc.birth_number AS rodne_cislo,
    
    COALESCE(jp.name->>'cs', jp.name_in_contract) AS pracovni_pozice,
    
    jp.wage AS zakladni_mzda,
    COALESCE(jp.wage_variable_component1, 0) AS variabilni_slozko_1,
    COALESCE(jp.wage_variable_component2, 0) AS variabilni_slozko_2,
    
    (jp.wage + COALESCE(jp.wage_variable_component1, 0) + COALESCE(jp.wage_variable_component2, 0)) AS celkovy_plat,
    
    pc.valid_from AS plati_od

FROM person_contracts pc
JOIN people p ON pc.person_id = p.id
JOIN person_contract_job_positions pcjp ON pcjp.person_contract_id = pc.id
JOIN job_positions jp ON pcjp.job_position_id = jp.id

WHERE pc.deleted = false
  AND (pc.valid_to IS NULL OR pc.valid_to >= CURRENT_DATE)
ORDER BY p.lastname ASC, p.firstname ASC;
