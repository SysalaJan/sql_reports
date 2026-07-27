WITH dochazka AS (
    SELECT 
        p.id AS person_id,
        CAST(p.lastname || ' ' || p.firstname AS VARCHAR) AS name,
        CAST(REGEXP_REPLACE(
            COALESCE(cc.name ->> '2', cc.name ->> '1', cc.name ->> 'cs', CAST(cc.name AS VARCHAR)), 
            '^[0-9]+\s+', ''
        ) AS VARCHAR) AS pracoviste,
        CAST(a.time AS DATE) AS datum,
        MIN(CASE WHEN a.type = 'ARRIVE' THEN a.time END) AS prichod,
        MAX(CASE WHEN a.type = 'LEAVE' THEN a.time END) AS odchod
    FROM attendance_records a
    JOIN people p ON p.id = a.person_id
    LEFT JOIN cost_centers cc ON cc.id = p.cost_center_id
    GROUP BY p.id, p.lastname, p.firstname, cc.name, CAST(a.time AS DATE)
),
zaznam_prace_soucet AS (
    SELECT 
        p.id AS person_id,
        CAST(p.lastname || ' ' || p.firstname AS VARCHAR) AS name,
        CAST(REGEXP_REPLACE(
            COALESCE(cc.name ->> '2', cc.name ->> '1', cc.name ->> 'cs', CAST(cc.name AS VARCHAR)), 
            '^[0-9]+\s+', ''
        ) AS VARCHAR) AS pracoviste,
        CAST(wr.started_at AS DATE) AS datum,
        MIN(wr.started_at) AS prvni_zapis,
        MAX(wr.created_at) AS posledni_zapis,
        COUNT(wr.id) AS pocet_davek,
        ROUND(CAST(SUM(COALESCE(wr.worker_minutes, 0.0)) / 60.0 AS NUMERIC), 2) AS hodiny_prace_ciste
    FROM work_records wr
    JOIN people p ON p.id = wr.person_id
    LEFT JOIN cost_centers cc ON cc.id = p.cost_center_id
    WHERE wr.deleted = false
    GROUP BY p.id, p.lastname, p.firstname, cc.name, CAST(wr.started_at AS DATE)
),
nepracovni_aktivity_soucet AS (
    SELECT 
        person_id,
        CAST(started_at AS DATE) AS datum,
        ROUND(CAST(SUM(EXTRACT(EPOCH FROM (COALESCE(finished_at, NOW()) - started_at))) / 3600.0 AS NUMERIC), 2) AS hodiny_nepracovni_aktivity
    FROM activities
    WHERE operation_id IS NULL
      AND deleted = false
    GROUP BY person_id, CAST(started_at AS DATE)
),
vypocet_casu AS (
    SELECT 
        COALESCE(d.datum, p.datum, n.datum) AS datum,
        COALESCE(d.person_id, p.person_id, n.person_id) AS person_id,
        CAST(COALESCE(d.name, p.name) AS VARCHAR) AS zamestnanec,
        CAST(COALESCE(d.pracoviste, p.pracoviste) AS VARCHAR) AS pracoviste,
        d.prichod AS d_prichod,
        
        CASE 
            WHEN d.odchod IS NOT NULL THEN d.odchod
            WHEN d.prichod IS NOT NULL AND p.posledni_zapis IS NOT NULL THEN p.posledni_zapis
            WHEN d.prichod IS NOT NULL THEN d.prichod + INTERVAL '8 hours'
            ELSE NULL 
        END AS d_odchod_upraveny,
        
        CAST(CASE 
            WHEN d.prichod IS NOT NULL AND d.odchod IS NULL THEN 'CHYBÍ ODCHOD (dopočteno)'
            WHEN d.prichod IS NULL AND (p.hodiny_prace_ciste > 0 OR n.hodiny_nepracovni_aktivity > 0) THEN 'CHYBÍ DOCHÁZKA (práce existuje)'
            WHEN d.prichod IS NULL THEN 'CHYBÍ PŘÍCHOD'
            ELSE 'V pořádku'
        END AS VARCHAR) AS stav_dochazky,
        
        p.prvni_zapis AS wr_prvni_prace,
        p.posledni_zapis AS wr_posledni_prace,
        p.pocet_davek AS wr_pocet_davek,
        COALESCE(p.hodiny_prace_ciste, 0.00) AS hodiny_prace_ciste,
        COALESCE(n.hodiny_nepracovni_aktivity, 0.00) AS hodiny_nepracovni_aktivity,
        
        EXTRACT(EPOCH FROM (
            CASE 
                WHEN d.odchod IS NOT NULL THEN d.odchod
                WHEN d.prichod IS NOT NULL AND p.posledni_zapis IS NOT NULL THEN p.posledni_zapis
                WHEN d.prichod IS NOT NULL THEN d.prichod + INTERVAL '8 hours'
                ELSE NULL 
            END - d.prichod
        )) / 3600.0 AS hrube_hodiny_internal
    FROM dochazka d
    FULL OUTER JOIN zaznam_prace_soucet p ON d.person_id = p.person_id AND d.datum = p.datum
    LEFT JOIN nepracovni_aktivity_soucet n ON n.person_id = COALESCE(d.person_id, p.person_id) AND n.datum = COALESCE(d.datum, p.datum)
),
celkove_vypocty AS (
    SELECT 
        v.*,
        ROUND(CAST(
            CASE 
                WHEN v.hrube_hodiny_internal IS NOT NULL THEN v.hrube_hodiny_internal - 0.5
                ELSE 0.0
            END AS NUMERIC), 2) AS hodiny_dochazka_ciste
    FROM vypocet_casu v
)
SELECT 
    f.datum,
    f.zamestnanec,
    f.pracoviste,
    f.stav_dochazky,
    f.d_prichod,
    f.d_odchod_upraveny AS d_odchod,
    f.wr_prvni_prace,
    f.wr_posledni_prace,
    COALESCE(f.wr_pocet_davek, 0) AS wr_pocet_davek,
    
    f.hodiny_dochazka_ciste AS hodiny_dochazka,
    f.hodiny_prace_ciste AS hodiny_prace_ciste,
    f.hodiny_nepracovni_aktivity AS hodiny_nepracovni,
    
    ROUND(CAST(
        (f.hodiny_prace_ciste + f.hodiny_nepracovni_aktivity) - f.hodiny_dochazka_ciste
    AS NUMERIC), 2) AS rozdil_celkem_hodin
FROM celkove_vypocty f
ORDER BY f.datum DESC, f.zamestnanec;
