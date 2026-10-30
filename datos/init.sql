-- =====================================================================
-- TAREA 8 · Programacion del lado del servidor: creacion de funciones
-- IoT Analytics Dashboard (NexoDev Solutions) · PostgreSQL 16
-- Las funciones encapsulan la logica reutilizable: registrar lecturas con
-- validacion y alertas, calcular promedios en tiempo real, estadisticas y
-- prediccion. Los usuarios solo ejecutan funciones; nadie toca las tablas.
-- =====================================================================

-- ------------------------------ TABLAS ------------------------------
CREATE TABLE dispositivos (
    id        SERIAL PRIMARY KEY,
    codigo    VARCHAR(20) NOT NULL UNIQUE,
    nombre    VARCHAR(60) NOT NULL,
    ubicacion VARCHAR(60) NOT NULL,
    estado    VARCHAR(15) NOT NULL DEFAULT 'activo'
              CHECK (estado IN ('activo', 'mantenimiento', 'inactivo'))
);

CREATE TABLE sensores (
    id             SERIAL PRIMARY KEY,
    dispositivo_id INT NOT NULL REFERENCES dispositivos(id),
    codigo         VARCHAR(20) NOT NULL UNIQUE,
    tipo           VARCHAR(20) NOT NULL CHECK (tipo IN ('temperatura', 'vibracion', 'energia')),
    unidad         VARCHAR(10) NOT NULL,
    umbral_max     NUMERIC(10,2) NOT NULL
);

CREATE TABLE lecturas (
    id        BIGSERIAL PRIMARY KEY,
    sensor_id INT NOT NULL REFERENCES sensores(id),
    valor     NUMERIC(10,2) NOT NULL,
    medido_en TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_lecturas_sensor_fecha ON lecturas (sensor_id, medido_en DESC);
CREATE INDEX idx_lecturas_fecha        ON lecturas (medido_en DESC);

CREATE TABLE alertas (
    id         SERIAL PRIMARY KEY,
    lectura_id BIGINT NOT NULL REFERENCES lecturas(id),
    sensor_id  INT NOT NULL REFERENCES sensores(id),
    severidad  VARCHAR(12) NOT NULL CHECK (severidad IN ('advertencia', 'critica')),
    valor      NUMERIC(10,2) NOT NULL,
    umbral     NUMERIC(10,2) NOT NULL,
    creada_en  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    atendida   BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE INDEX idx_alertas_pendientes ON alertas (creada_en DESC) WHERE NOT atendida;

-- ============================== FUNCIONES ==============================

-- F1. Clasificar una lectura (funcion escalar pura).
-- IMMUTABLE: con los mismos parametros siempre devuelve lo mismo; el
-- planificador puede evaluarla una sola vez. La reutilizan F3, F5 y F6.
CREATE FUNCTION fn_clasificar_lectura(p_valor NUMERIC, p_umbral NUMERIC)
RETURNS TEXT
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE
        WHEN p_valor IS NULL               THEN 'sin datos'
        WHEN p_valor > p_umbral * 1.2      THEN 'critica'
        WHEN p_valor > p_umbral            THEN 'advertencia'
        ELSE 'normal'
    END;
$$;

-- F2. Rango fisico valido por tipo de sensor (funcion escalar con 3 parametros).
CREATE FUNCTION fn_valor_valido(p_tipo TEXT, p_valor NUMERIC)
RETURNS BOOLEAN
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE p_tipo
        WHEN 'temperatura' THEN p_valor BETWEEN -40 AND 150
        WHEN 'vibracion'   THEN p_valor BETWEEN 0 AND 50
        WHEN 'energia'     THEN p_valor BETWEEN 0 AND 1000
        ELSE FALSE
    END;
$$;

-- F3. Registrar una lectura (procedimiento con validacion y transaccion).
-- Valida sensor, estado del dispositivo y rango; inserta la lectura y,
-- si supera el umbral, la alerta. Devuelve una fila con el resultado.
-- SECURITY DEFINER: el consumidor solo tiene EXECUTE, no INSERT en tablas.
CREATE FUNCTION fn_registrar_lectura(
    p_sensor    TEXT,
    p_valor     NUMERIC,
    p_medido_en TIMESTAMPTZ DEFAULT NOW()
)
RETURNS TABLE (lectura_id BIGINT, situacion TEXT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
    v_sensor   sensores%ROWTYPE;
    v_estado   TEXT;
    v_id       BIGINT;
    v_sit      TEXT;
BEGIN
    SELECT s.* INTO v_sensor FROM sensores s WHERE s.codigo = p_sensor;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El sensor % no existe', p_sensor USING ERRCODE = 'no_data_found';
    END IF;

    SELECT d.estado INTO v_estado FROM dispositivos d WHERE d.id = v_sensor.dispositivo_id;
    IF v_estado <> 'activo' THEN
        RAISE EXCEPTION 'El dispositivo de % esta en %', p_sensor, v_estado
              USING ERRCODE = 'object_not_in_prerequisite_state';
    END IF;

    IF NOT fn_valor_valido(v_sensor.tipo, p_valor) THEN
        RAISE EXCEPTION 'Valor % fuera del rango fisico de %', p_valor, v_sensor.tipo
              USING ERRCODE = 'numeric_value_out_of_range';
    END IF;

    INSERT INTO lecturas (sensor_id, valor, medido_en)
    VALUES (v_sensor.id, p_valor, p_medido_en)
    RETURNING id INTO v_id;

    v_sit := fn_clasificar_lectura(p_valor, v_sensor.umbral_max);
    IF v_sit IN ('advertencia', 'critica') THEN
        INSERT INTO alertas (lectura_id, sensor_id, severidad, valor, umbral, creada_en)
        VALUES (v_id, v_sensor.id, v_sit, p_valor, v_sensor.umbral_max, p_medido_en);
    END IF;

    RETURN QUERY SELECT v_id, v_sit;
END $$;

-- F4. Promedio en tiempo real de un sensor (escalar con parametro por defecto).
-- STABLE: no modifica datos; dentro de una consulta devuelve lo mismo.
-- Usa el indice (sensor_id, medido_en DESC): solo lee la ventana pedida.
CREATE FUNCTION fn_promedio_sensor(p_sensor TEXT, p_minutos INT DEFAULT 10)
RETURNS NUMERIC
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT ROUND(AVG(l.valor), 2)
    FROM lecturas l
    JOIN sensores s ON s.id = l.sensor_id
    WHERE s.codigo = p_sensor
      AND l.medido_en > NOW() - make_interval(mins => p_minutos);
$$;

-- F5. Estadisticas de un sensor en un periodo (parametros OUT -> un registro).
CREATE FUNCTION fn_estadisticas_sensor(
    p_sensor TEXT,
    p_desde  TIMESTAMPTZ,
    p_hasta  TIMESTAMPTZ DEFAULT NOW(),
    OUT lecturas      BIGINT,
    OUT promedio      NUMERIC,
    OUT minimo        NUMERIC,
    OUT maximo        NUMERIC,
    OUT desviacion    NUMERIC,
    OUT sobre_umbral  BIGINT,
    OUT situacion     TEXT
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT COUNT(*),
           ROUND(AVG(l.valor), 2),
           MIN(l.valor),
           MAX(l.valor),
           ROUND(STDDEV_SAMP(l.valor), 2),
           COUNT(*) FILTER (WHERE l.valor > s.umbral_max),
           fn_clasificar_lectura(MAX(l.valor), s.umbral_max)
    FROM sensores s
    LEFT JOIN lecturas l ON l.sensor_id = s.id
                        AND l.medido_en >= p_desde AND l.medido_en < p_hasta
    WHERE s.codigo = p_sensor
    GROUP BY s.umbral_max;
$$;

-- F6. Serie de promedios por intervalo (funcion de tabla para Grafana).
-- date_bin agrupa en cubetas del tamano pedido (1 min, 5 min, 1 h...).
CREATE FUNCTION fn_serie_promedios(
    p_tipo      TEXT,
    p_desde     TIMESTAMPTZ,
    p_hasta     TIMESTAMPTZ DEFAULT NOW(),
    p_intervalo INTERVAL DEFAULT '1 minute'
)
RETURNS TABLE (tiempo TIMESTAMPTZ, sensor TEXT, promedio NUMERIC, maximo NUMERIC, situacion TEXT)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    SELECT date_bin(p_intervalo, l.medido_en, TIMESTAMPTZ '2000-01-01') AS tiempo,
           s.codigo::TEXT,
           ROUND(AVG(l.valor), 2),
           MAX(l.valor),
           fn_clasificar_lectura(MAX(l.valor), s.umbral_max)
    FROM lecturas l
    JOIN sensores s ON s.id = l.sensor_id
    WHERE s.tipo = p_tipo
      AND l.medido_en >= p_desde AND l.medido_en < p_hasta
    GROUP BY 1, 2, s.umbral_max
    ORDER BY 1, 2;
$$;

-- F7. Prediccion por regresion lineal (funcion de tabla con varios calculos).
-- Ajusta una recta a los promedios por minuto de las ultimas p_horas y
-- proyecta p_horizonte minutos. regr_r2 mide la confianza (0 a 1).
CREATE FUNCTION fn_prediccion(p_horas INT DEFAULT 3, p_horizonte INT DEFAULT 30)
RETURNS TABLE (sensor TEXT, actual NUMERIC, proyectado NUMERIC, umbral NUMERIC,
               pendiente_hora NUMERIC, confianza NUMERIC, minutos_al_umbral NUMERIC, riesgo TEXT)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
    WITH por_minuto AS (
        SELECT l.sensor_id,
               EXTRACT(EPOCH FROM date_trunc('minute', l.medido_en)) / 60 AS x,
               AVG(l.valor) AS y
        FROM lecturas l
        WHERE l.medido_en > NOW() - make_interval(hours => p_horas)
        GROUP BY 1, 2
    ), recta AS (
        SELECT sensor_id,
               regr_slope(y, x)     AS m,
               regr_intercept(y, x) AS b,
               regr_r2(y, x)        AS r2,
               MAX(x)               AS x_actual,
               COUNT(*)             AS puntos
        FROM por_minuto
        GROUP BY sensor_id
        HAVING COUNT(*) >= 10                       -- minimo de datos para predecir
    )
    SELECT s.codigo::TEXT,
           ROUND((r.m * r.x_actual + r.b)::NUMERIC, 2),
           ROUND((r.m * (r.x_actual + p_horizonte) + r.b)::NUMERIC, 2),
           s.umbral_max,
           ROUND((r.m * 60)::NUMERIC, 3),
           ROUND(COALESCE(r.r2, 0)::NUMERIC, 2),
           CASE WHEN r.m > 0 AND COALESCE(r.r2, 0) >= 0.3 AND (r.m * r.x_actual + r.b) < s.umbral_max
                THEN ROUND(((s.umbral_max - (r.m * r.x_actual + r.b)) / r.m)::NUMERIC, 0) END,
           CASE WHEN COALESCE(r.r2, 0) < 0.3 THEN 'sin tendencia'
                WHEN r.m * (r.x_actual + p_horizonte) + r.b > s.umbral_max THEN 'riesgo de pico'
                WHEN r.m > 0 THEN 'subiendo'
                ELSE 'estable' END
    FROM recta r
    JOIN sensores s     ON s.id = r.sensor_id
    JOIN dispositivos d ON d.id = s.dispositivo_id
    WHERE d.estado = 'activo'                       -- sin falsas alarmas en mantenimiento
    ORDER BY s.codigo;
$$;

-- F8. Version ingenua de F4, solo para la prueba de rendimiento:
-- recorre las lecturas fila por fila con un ciclo en PL/pgSQL.
CREATE FUNCTION fn_promedio_sensor_ciclo(p_sensor TEXT, p_minutos INT DEFAULT 10)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
    r      RECORD;
    v_suma NUMERIC := 0;
    v_n    INT := 0;
BEGIN
    FOR r IN SELECT l.valor, l.medido_en, s.codigo
             FROM lecturas l JOIN sensores s ON s.id = l.sensor_id LOOP
        IF r.codigo = p_sensor AND r.medido_en > NOW() - make_interval(mins => p_minutos) THEN
            v_suma := v_suma + r.valor;
            v_n := v_n + 1;
        END IF;
    END LOOP;
    RETURN CASE WHEN v_n > 0 THEN ROUND(v_suma / v_n, 2) END;
END $$;

-- ------------------------- USUARIOS Y PERMISOS -------------------------
-- Por defecto PostgreSQL deja ejecutar cualquier funcion a todos: se quita
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;

-- Consumidor de RabbitMQ: solo puede registrar lecturas a traves de F3
CREATE ROLE consumidor_iot LOGIN PASSWORD 'consumidor123';
GRANT EXECUTE ON FUNCTION fn_registrar_lectura(TEXT, NUMERIC, TIMESTAMPTZ) TO consumidor_iot;

-- Grafana: solo funciones de consulta, ninguna tabla
CREATE ROLE grafana_lector LOGIN PASSWORD 'grafana123';
GRANT EXECUTE ON FUNCTION
    fn_clasificar_lectura(NUMERIC, NUMERIC),
    fn_promedio_sensor(TEXT, INT),
    fn_estadisticas_sensor(TEXT, TIMESTAMPTZ, TIMESTAMPTZ),
    fn_serie_promedios(TEXT, TIMESTAMPTZ, TIMESTAMPTZ, INTERVAL),
    fn_prediccion(INT, INT)
TO grafana_lector;

-- --------------------------- DATOS INICIALES ---------------------------
INSERT INTO dispositivos (codigo, nombre, ubicacion) VALUES
('PRE-03', 'Prensa hidraulica 3', 'Linea 1'),
('TOR-01', 'Torno CNC 1',        'Linea 2'),
('EMB-02', 'Embotelladora 2',    'Linea 3');

INSERT INTO sensores (dispositivo_id, codigo, tipo, unidad, umbral_max) VALUES
(1, 'PRE03-TEMP', 'temperatura', '°C',   85.00),
(1, 'PRE03-VIB',  'vibracion',   'mm/s',  7.00),
(1, 'PRE03-ENE',  'energia',     'kWh',  30.00),
(2, 'TOR01-TEMP', 'temperatura', '°C',   80.00),
(2, 'TOR01-VIB',  'vibracion',   'mm/s',  6.00),
(2, 'TOR01-ENE',  'energia',     'kWh',  25.00),
(3, 'EMB02-TEMP', 'temperatura', '°C',   75.00),
(3, 'EMB02-VIB',  'vibracion',   'mm/s',  5.00),
(3, 'EMB02-ENE',  'energia',     'kWh',  20.00);

-- Historico de 3 dias (una lectura cada 30 s por sensor) para las pruebas de rendimiento.
-- PRE03-TEMP sube poco a poco en las ultimas 3 horas para probar la prediccion.
SELECT setseed(0.8);
INSERT INTO lecturas (sensor_id, valor, medido_en)
SELECT s.id,
       ROUND((s.umbral_max * (0.80 + (random() - 0.5) * 0.06)
              + CASE WHEN s.codigo = 'PRE03-TEMP' AND t > NOW() - INTERVAL '3 hours'
                     THEN EXTRACT(EPOCH FROM t - (NOW() - INTERVAL '3 hours')) / 3600 * 5
                     ELSE 0 END)::numeric, 2),
       t
FROM sensores s
CROSS JOIN generate_series(NOW() - INTERVAL '3 days', NOW() - INTERVAL '1 minute',
                           INTERVAL '30 seconds') AS t;
ANALYZE;
