# IoT Analytics Dashboard · Funciones en PostgreSQL (Tarea 8)

NexoDev Solutions · Programación de Base de Datos (TESE) · Luis Gael Monterrubio López

## Documentación

📄 [Abrir la documentación de la Tarea 8 (PDF)](docs/Documentacion_Tarea8.pdf)

Funciones en PostgreSQL 16 que encapsulan la lógica reutilizable del tablero: registrar lecturas con validación y alertas, promedios en tiempo real, estadísticas y predicción por regresión lineal. Las lecturas llegan en tiempo real por RabbitMQ y Grafana grafica llamando a las funciones.

```
Simulador ──► RabbitMQ ──► Consumidor ──► fn_registrar_lectura() ──► PostgreSQL ◄── Grafana
            (red-mensajes)              (red-datos, SSL)         llama funciones de consulta
```

## Funciones

| Función | Tipo | Qué hace |
|---|---|---|
| `fn_clasificar_lectura(valor, umbral)` | Escalar `IMMUTABLE` | normal, advertencia (> umbral) o crítica (> umbral + 20 %) |
| `fn_valor_valido(tipo, valor)` | Escalar `IMMUTABLE` | Valida el rango físico por tipo de sensor |
| `fn_registrar_lectura(sensor, valor, fecha)` | PL/pgSQL, devuelve tabla | Valida, inserta la lectura y genera la alerta en una transacción |
| `fn_promedio_sensor(sensor, minutos = 10)` | Escalar `STABLE` | Promedio en tiempo real de un sensor |
| `fn_estadisticas_sensor(sensor, desde, hasta)` | Parámetros `OUT` | Lecturas, promedio, mínimo, máximo, desviación y lecturas sobre umbral |
| `fn_serie_promedios(tipo, desde, hasta, intervalo)` | Devuelve tabla | Serie de promedios para las gráficas de Grafana |
| `fn_prediccion(horas = 3, horizonte = 30)` | Devuelve tabla | Regresión lineal: valor proyectado, confianza (R²) y riesgo de pico |

## Usuarios

| Usuario | Permisos |
|---|---|
| `consumidor_iot` | Solo `EXECUTE` sobre `fn_registrar_lectura` (no puede insertar en tablas) |
| `grafana_lector` | Solo `EXECUTE` sobre las funciones de consulta (no puede leer tablas) |

## Levantar

```bash
docker compose up -d --build
```

- Grafana: http://localhost:3008 (admin / admin123)
- RabbitMQ: http://localhost:15678 (iot / iot123)

Pruebas de funcionamiento y rendimiento:

```bash
docker exec -i funciones-datos psql -U postgres -d iotanalytics < datos/pruebas.sql
```
