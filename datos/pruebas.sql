-- =====================================================================
-- Pruebas de la Tarea 8: funcionamiento y rendimiento de las funciones
-- =====================================================================
\pset footer off

\echo '=== F1 y F2: funciones escalares ==='
SELECT fn_clasificar_lectura(70, 85)  AS "70 de 85",
       fn_clasificar_lectura(90, 85)  AS "90 de 85",
       fn_clasificar_lectura(105, 85) AS "105 de 85",
       fn_valor_valido('vibracion', 99) AS "vibracion 99 valida";

\echo '=== F5: estadisticas de TOR01-TEMP del ultimo dia ==='
SELECT * FROM fn_estadisticas_sensor('TOR01-TEMP', NOW() - INTERVAL '1 day');

\echo '=== F7: prediccion a 30 minutos ==='
SELECT * FROM fn_prediccion(3, 30);

\echo '=== Rendimiento: misma operacion con ciclo fila por fila y con SQL ==='
\timing on
SELECT fn_promedio_sensor_ciclo('PRE03-VIB', 10) AS promedio_ciclo;
SELECT fn_promedio_sensor('PRE03-VIB', 10)       AS promedio_sql;
\timing off

\echo '=== Plan de la consulta de F4: usa el indice por sensor y fecha ==='
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY ON)
SELECT ROUND(AVG(l.valor), 2)
FROM lecturas l JOIN sensores s ON s.id = l.sensor_id
WHERE s.codigo = 'PRE03-VIB' AND l.medido_en > NOW() - INTERVAL '10 minutes';
