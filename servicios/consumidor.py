"""
Consumidor: toma las lecturas de RabbitMQ y las registra llamando a la
funcion fn_registrar_lectura() con el usuario consumidor_iot, que solo tiene
permiso de EXECUTE sobre esa funcion. Toda la validacion y la generacion de
alertas vive en la base de datos.
"""
import json
import os
import time

import pika
import psycopg

CONNINFO = (f"host={os.getenv('DB_HOST', 'datos')} dbname=iotanalytics "
            f"user={os.getenv('DB_USER', 'consumidor_iot')} "
            f"password={os.environ['DB_PASSWORD']} sslmode=require")

REGISTRAR = "SELECT lectura_id, situacion FROM fn_registrar_lectura(%s::text, %s::numeric, %s::timestamptz)"


def conectar_bd():
    while True:
        try:
            return psycopg.connect(CONNINFO, autocommit=True)
        except psycopg.OperationalError:
            print("PostgreSQL no disponible, reintentando...")
            time.sleep(3)


def conectar_rabbit():
    params = pika.URLParameters(os.getenv("RABBIT_URL", "amqp://iot:iot123@mensajes:5672/"))
    while True:
        try:
            return pika.BlockingConnection(params)
        except pika.exceptions.AMQPConnectionError:
            print("RabbitMQ no disponible, reintentando...")
            time.sleep(3)


def main():
    bd = conectar_bd()
    print("Conectado a PostgreSQL con SSL:", bd.info.pgconn.ssl_in_use)
    con = conectar_rabbit()
    canal = con.channel()
    canal.queue_declare(queue="lecturas", durable=True)
    canal.basic_qos(prefetch_count=50)
    cuenta = {"guardadas": 0, "alertas": 0, "rechazadas": 0}

    def al_recibir(ch, metodo, _props, cuerpo):
        lectura = json.loads(cuerpo)
        try:
            _id, situacion = bd.execute(REGISTRAR, (lectura["sensor"], lectura["valor"],
                                                     lectura["medido_en"])).fetchone()
            cuenta["guardadas"] += 1
            if situacion in ("advertencia", "critica"):
                cuenta["alertas"] += 1
                print(f"Alerta {situacion}: {lectura['sensor']} = {lectura['valor']}")
        except psycopg.Error as e:          # la funcion rechazo la lectura (RAISE EXCEPTION)
            cuenta["rechazadas"] += 1
            print(f"Rechazada [{e.sqlstate}]: {e.diag.message_primary}")
        ch.basic_ack(delivery_tag=metodo.delivery_tag)

    def reporte():
        print(f"{cuenta['guardadas']} guardadas · {cuenta['alertas']} alertas · "
              f"{cuenta['rechazadas']} rechazadas")
        con.call_later(30, reporte)

    con.call_later(30, reporte)
    canal.basic_consume(queue="lecturas", on_message_callback=al_recibir)
    print("Consumidor escuchando la cola 'lecturas'")
    canal.start_consuming()


if __name__ == "__main__":
    main()
