WITH predfiltrovana_prace AS (
    SELECT 
        person_id,
        CAST(started_at AS DATE) AS datum,
        started_at,
        GREATEST(started_at, CAST(started_at AS DATE) + INTERVAL '6 hours') AS started_at_pro_vypocet,
        worker_minutes
    FROM work_records
    WHERE deleted = false
),
ciste_hodiny_prace AS (
    SELECT 
        person_id,
        datum,
        ROUND(CAST(
            LEAST(
                EXTRACT(EPOCH FROM (MAX(started_at_pro_vypocet + (COALESCE(worker_minutes, 0.0) * INTERVAL '1 minute')) - MIN(started_at_pro_vypocet))) / 3600.0,
                SUM(COALESCE(worker_minutes, 0.0)) / 60.0
            )
        AS NUMERIC), 2) AS hodiny_prace_ciste
    FROM predfiltrovana_prace
    GROUP BY person_id, datum
),
dochazka AS (
    SELECT 
        p.id AS person_id,
        CAST(p.lastname || ' ' || p.firstname AS VARCHAR) AS name,
        CAST(REGEXP_REPLACE(COALESCE(cc.name ->> '2', cc.name ->> '1', cc.name ->> 'cs', CAST(cc.name AS VARCHAR)), '^[0-9]+\s+', '') AS VARCHAR) AS pracoviste,
        CAST(a.time AS DATE) AS datum,
        MIN(CASE WHEN a.type = 'ARRIVE' THEN a.time END) AS prichod_surovy,
        MAX(CASE WHEN a.type = 'LEAVE' THEN a.time END) AS odchod
    FROM attendance_records a
    JOIN people p ON p.id = a.person_id
    LEFT JOIN cost_centers cc ON cc.id = p.cost_center_id
    GROUP BY p.id, p.lastname, p.firstname, cc.name, CAST(a.time AS DATE)
),
zaznam_prace_metadat AS (
    SELECT 
        p.id AS person_id,
        CAST(wr.started_at AS DATE) AS datum,
        MIN(wr.started_at) AS prvni_zapis_surovy,
        MAX(wr.created_at) AS posledni_zapis,
        COUNT(wr.id) AS pocet_davek
    FROM work_records wr
    JOIN people p ON p.id = wr.person_id
    WHERE wr.deleted = false
    GROUP BY p.id, CAST(wr.started_at AS DATE)
),
zakladni_prehled AS (
    SELECT 
        COALESCE(d.datum, p.datum) AS datum,
        COALESCE(d.person_id, p.person_id) AS person_id,
        CAST(COALESCE(d.name, (SELECT px.lastname || ' ' || px.firstname FROM people px WHERE px.id = p.person_id)) AS VARCHAR) AS zamestnanec,
        CAST(COALESCE(d.pracoviste, (SELECT CAST(REGEXP_REPLACE(COALESCE(ccx.name ->> '2', ccx.name ->> '1', ccx.name ->> 'cs', CAST(ccx.name AS VARCHAR)), '^[0-9]+\s+', '') AS VARCHAR) FROM people pxx LEFT JOIN cost_centers ccx ON ccx.id = pxx.cost_center_id WHERE pxx.id = p.person_id)) AS VARCHAR) AS pracoviste,
        
        d.prichod_surovy AS d_prichod,
        CASE 
            WHEN d.odchod IS NOT NULL THEN d.odchod
            WHEN d.prichod_surovy IS NOT NULL AND p.posledni_zapis IS NOT NULL THEN p.posledni_zapis
            ELSE d.prichod_surovy + INTERVAL '8 hours' 
        END AS d_odchod,
        p.prvni_zapis_surovy AS wr_prvni_prace,
        p.posledni_zapis AS wr_posledni_prace,
        COALESCE(p.pocet_davek, 0) AS wr_pocet_davek,
        
        GREATEST(d.prichod_surovy, COALESCE(d.datum, p.datum) + INTERVAL '6 hours') AS prichod_pro_vypocet
    FROM dochazka d
    FULL OUTER JOIN zaznam_prace_metadat p ON d.person_id = p.person_id AND d.datum = p.datum
),
vypocet_casu AS (
    SELECT 
        zp.*,
        COALESCE(chp.hodiny_prace_ciste, 0.00) AS hodiny_prace_ciste,
        
        COALESCE((
            SELECT ROUND(CAST(SUM(EXTRACT(EPOCH FROM (act.finished_at - GREATEST(act.started_at, CAST(act.started_at AS DATE) + INTERVAL '6 hours')))) / 3600.0 AS NUMERIC), 2)
            FROM activities act
            WHERE act.person_id = zp.person_id 
              AND CAST(act.started_at AS DATE) = zp.datum
              AND act.deleted = false
              AND act.operation_id IS NULL 
              AND act.batch_id IS NULL     
              AND act.finished_at IS NOT NULL
              AND act.finished_at > CAST(act.started_at AS DATE) + INTERVAL '6 hours'
              AND act.finished_at - act.started_at < INTERVAL '12 hours'
        ), 0.00) AS hodiny_nepracovni_surove
    FROM zakladni_prehled zp
    LEFT JOIN ciste_hodiny_prace chp ON chp.person_id = zp.person_id AND chp.datum = zp.datum
),
celkove_vypocty AS (
    SELECT 
        v.*,
        CASE 
            WHEN v.hodiny_prace_ciste = v.hodiny_nepracovni_surove THEN 0.00
            ELSE v.hodiny_nepracovni_surove
        END AS hodiny_nepracovni,
        
        EXTRACT(EPOCH FROM (v.d_odchod - v.prichod_pro_vypocet)) / 3600.0 AS hrube_hodiny_internal
    FROM vypocet_casu v
)
SELECT 
    f.datum,
    f.zamestnanec,
    f.pracoviste,
    CASE 
        WHEN f.d_prichod IS NOT NULL AND f.d_odchod IS NULL THEN 'CHYBÍ ODCHOD (dopočteno)'
        WHEN f.d_prichod IS NULL AND (f.hodiny_prace_ciste > 0 OR f.hodiny_nepracovni > 0) THEN 'CHYBÍ DOCHÁZKA'
        ELSE 'V pořádku'
    END AS stav_dochazky,
    
    f.d_prichod,
    f.d_odchod,
    f.wr_prvni_prace,
    f.wr_posledni_prace,
    f.wr_pocet_davek,
    
    ROUND(CAST(CASE WHEN f.hrube_hodiny_internal IS NOT NULL THEN GREATEST(f.hrube_hodiny_internal - 0.5, 0.0) ELSE 0.0 END AS NUMERIC), 2) AS hodiny_dochazka,
    f.hodiny_prace_ciste AS hodiny_prace_ciste,
    f.hodiny_nepracovni AS hodiny_nepracovni,
    
    ROUND(CAST(
        (f.hodiny_prace_ciste + f.hodiny_nepracovni) - CASE WHEN f.hrube_hodiny_internal IS NOT NULL THEN GREATEST(f.hrube_hodiny_internal - 0.5, 0.0) ELSE 0.0 END
    AS NUMERIC), 2) AS rozdil_celkem_hodin
FROM celkove_vypocty f
WHERE f.zamestnanec IS NOT NULL
ORDER BY f.datum DESC, f.zamestnanec
