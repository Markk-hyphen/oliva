# Conceptos técnicos

Explicaciones teóricas de tecnologías y conceptos usados en el proyecto.
Cada sección se agrega a medida que el tema aparece en el desarrollo.

---

## pgvector

### Qué es

`pgvector` es una extensión de PostgreSQL que agrega un tipo de dato nativo llamado `vector` y operadores para hacer **búsqueda por similitud** entre vectores. En términos simples: te permite guardar y comparar listas de números flotantes directamente en tu base de datos Postgres existente, sin necesidad de una base de datos vectorial separada (Pinecone, Weaviate, Qdrant, etc.).

### Para qué sirve en este proyecto

Cuando un modelo de IA procesa una noticia cripto, genera un **embedding**: una lista de ~1500 números flotantes que representan el *significado semántico* del texto. Dos noticias sobre el mismo tema tienen embeddings parecidos (vectorialmente cercanos); dos noticias sin relación tienen embeddings lejanos.

`pgvector` permite hacer consultas como:
> *"Dame las 5 noticias más similares semánticamente a esta query del usuario"*

sin mover los datos fuera de Postgres.

### Cómo funciona por dentro

Un embedding es un punto en un espacio de alta dimensión (por ejemplo, 1536 dimensiones si usás `text-embedding-3-small` de OpenAI). La "distancia" entre dos puntos mide qué tan parecidos son semánticamente.

`pgvector` soporta tres métricas de distancia:

| Operador | Métrica | Cuándo usarla |
|---|---|---|
| `<->` | L2 (distancia euclidiana) | cuando la magnitud importa |
| `<=>` | Cosine similarity | **la más común para texto** — mide ángulo, ignora magnitud |
| `<#>` | Inner product | embeddings normalizados |

Para texto casi siempre se usa **cosine similarity** (`<=>`).

### Índices: HNSW vs IVFFlat

Sin índice, una búsqueda de similitud es un *full scan* (compara el vector query contra todos los vectores de la tabla). Escala mal. `pgvector` ofrece dos índices aproximados (ANN - Approximate Nearest Neighbor):

**IVFFlat** (Inverted File with Flat quantization):
- Divide los vectores en `lists` clusters (centroides).
- Para buscar, primero encuentra los clusters más cercanos y solo escanea esos.
- Más rápido de construir, menos memoria.
- Necesita datos cargados *antes* de crear el índice para que los clusters sean buenos.
- Parámetro clave: `lists` (típicamente `sqrt(n_rows)`).

**HNSW** (Hierarchical Navigable Small World):
- Construye un grafo de navegación multinivel.
- Más lento de construir y más memoria, pero **mayor recall** (encuentra los vecinos correctos más seguido) y mejor latencia de query.
- Se puede construir antes de tener datos (crece dinámicamente).
- **Recomendado para producción** salvo que el índice sea muy grande.

En este proyecto usaremos **HNSW** para el campo `embedding` de la entidad `Enrichment`.

### Cómo se usa en Symfony/Doctrine

`pgvector` no tiene soporte nativo en Doctrine. Se necesita declarar un tipo custom que mapea el tipo SQL `vector(n)` a un array PHP de floats. El flujo es:

```
PHP array de floats → Doctrine Type custom → SQL vector(1536) en Postgres
```

En una entidad se declara así:

```php
#[ORM\Column(type: 'vector', length: 1536)]
private array $embedding = [];
```

Y en la migración se genera:

```sql
ALTER TABLE enrichment ADD COLUMN embedding vector(1536);
CREATE INDEX ON enrichment USING hnsw (embedding vector_cosine_ops);
```

Para queries de similitud se usa SQL nativo o DQL con funciones custom:

```php
$em->createNativeQuery(
    'SELECT * FROM enrichment ORDER BY embedding <=> :query_vec LIMIT 5',
    $rsm
)->setParameter('query_vec', $queryEmbedding);
```

### Por qué en Postgres y no en una DB vectorial dedicada

Para la escala de este proyecto (miles/decenas de miles de noticias), `pgvector` es más que suficiente y tiene ventajas reales:

- **Un solo servicio menos** en Docker Compose.
- **Transacciones** — el embedding y los metadatos de la noticia se guardan atómicamente.
- **SQL estándar** — podés filtrar por fecha, source, sentiment *y* ordenar por similitud en una sola query.
- **Backup unificado** — un `pg_dump` y tenés todo.

Una DB vectorial dedicada tiene sentido a partir de decenas de millones de vectores o cuando necesitás features muy específicas (multi-tenancy vectorial, filtros complejos a escala masiva). No es el caso acá.

---

## RabbitMQ

### Qué es

RabbitMQ es un **message broker**: un proceso intermediario que recibe mensajes de un productor, los guarda en colas, y los entrega a uno o más consumidores. Es el equivalente a una oficina de correo: el que manda la carta (productor) no necesita saber quién la va a leer ni cuándo; solo la deposita, y el broker se ocupa de la entrega.

El protocolo que usa RabbitMQ se llama **AMQP** (Advanced Message Queuing Protocol).

### Conceptos clave

| Concepto | Qué es |
|---|---|
| **Producer** | Quien publica el mensaje (ej: el scheduler que encontró una noticia nueva) |
| **Exchange** | Punto de entrada. Recibe el mensaje y decide a qué colas mandarlo según reglas de routing |
| **Queue** | Buffer persistente donde esperan los mensajes hasta ser consumidos |
| **Consumer** | Quien procesa los mensajes (ej: el worker de Symfony que enriquece con IA) |
| **Binding** | Regla que conecta un exchange con una queue |
| **Routing key** | Etiqueta en el mensaje que usa el exchange para decidir el destino |

El flujo es siempre: `Producer → Exchange → Queue → Consumer`.

### Por qué no llamar directamente al worker

La alternativa "simple" sería que el scheduler llame al worker por HTTP o ejecute la lógica directamente. El problema:

- Si el worker se cae, el trabajo se pierde.
- Si llegan 50 noticias a la vez, el scheduler se bloquea esperando respuesta.
- No podés escalar consumidores sin cambiar el productor.

Con un broker en el medio:
- El mensaje **persiste en la cola** aunque el worker esté caído. Cuando vuelve, lo procesa.
- El scheduler termina en microsegundos (solo publica). El procesamiento es **asíncrono**.
- Podés levantar 5 workers en paralelo sin tocar el scheduler.

### Cómo se usa en este proyecto

El flujo de Crypto Pulse es:

```
[cron/scheduler]
     │ publica mensaje con URL/datos de la noticia
     ▼
[RabbitMQ - exchange "articles"]
     │ routing → queue "ingestion"
     ▼
[Symfony Worker - bin/console messenger:consume]
     │ consume el mensaje
     │ llama a Anthropic para enriquecer
     │ guarda en Postgres (con embedding en pgvector)
     ▼
[Mercure Hub]
     │ push SSE al frontend
     ▼
[Dashboard en vivo]
```

Symfony usa su componente **Messenger** para abstraer RabbitMQ: en el código PHP se hace `$bus->dispatch(new IngestArticleMessage(...))` y Messenger se encarga del transporte AMQP. No hay llamadas manuales a la librería de RabbitMQ.

### Por qué RabbitMQ y no Kafka o Redis Streams

Para este proyecto la elección es pragmática:

- **Kafka** es correcto para millones de mensajes/segundo y retención larga. Overkill para miles de noticias/día y agrega complejidad operativa real.
- **Redis Streams** es válido y más liviano, pero RabbitMQ tiene mejor integración nativa con **Symfony Messenger** (transport oficial, reintentos, dead-letter queues out of the box).
- **RabbitMQ** tiene UI de management (`localhost:15672`) que facilita debug en desarrollo.

La decisión está cerrada; RabbitMQ es el broker del proyecto.

---

## AMQP Routing y el bug de `default_publish_routing_key`

### El problema en una línea

Publicamos 18 mensajes al exchange `ingest`. La queue `ingest` quedó en 0. Los mensajes desaparecieron en silencio.

### Cómo funciona el routing en AMQP (tipo `direct`)

Un exchange `direct` es como un clasificador postal con reglas exactas:

```
Producer publica mensaje con routing_key="ingest"
         │
         ▼
   [Exchange "ingest" — tipo direct]
         │
         │  ¿hay algún binding cuya binding_key == routing_key del mensaje?
         │
    ─────┴─────────────────────────────────────
    SÍ: "ingest" == "ingest"        NO: descarta el mensaje (silencio)
         │
         ▼
   [Queue "ingest"]
```

El **binding** es el cable que conecta exchange con queue. Se define con una `binding_key`. Cuando llega un mensaje, el exchange compara el `routing_key` del mensaje contra la `binding_key` del binding. Si hay match exacto → entrega. Si no hay match → el mensaje se descarta **sin error, sin log, sin excepción**.

Esto es importante: **AMQP no falla ruidosamente cuando un mensaje no rutea. Lo descarta silenciosamente.** El producer recibe un "OK" del broker igualmente.

### Por qué pasó el bug

La configuración de Symfony Messenger era:

```yaml
transports:
    ingest:
        dsn: '%env(RABBITMQ_DSN)%'
        options:
            exchange:
                name: ingest
                type: direct
            queues:
                ingest:
                    binding_keys: [ingest]
```

Los `binding_keys: [ingest]` crean el binding `exchange → queue` con binding_key `"ingest"`. Eso es correcto.

El problema estaba en **qué routing_key usa Symfony al publicar**. El comportamiento de Symfony Messenger al publicar un mensaje a AMQP es:

```
routing_key = AmqpRoutingKeyStamp (si está presente en el envelope)
           ?? default_publish_routing_key (si está configurado en el exchange)
           ?? "" (string vacío — el default si no hay nada)
```

En nuestro caso, no había stamp ni `default_publish_routing_key`. Entonces Symfony publicó todos los mensajes con `routing_key = ""`.

El exchange recibió los mensajes (por eso `publish_in: 18`), buscó un binding con `binding_key == ""`, no encontró ninguno, y los descartó. La queue quedó en 0. Sin error.

### El fix

Agregar `default_publish_routing_key` al exchange:

```yaml
exchange:
    name: ingest
    type: direct
    default_publish_routing_key: ingest   # ← esto faltaba
```

Ahora Symfony publica con `routing_key = "ingest"`, que matchea `binding_key = "ingest"`, y el mensaje llega a la queue.

### Cómo se detectó

No hay ningún error en el lado del producer. El `$bus->dispatch(...)` retorna éxito. El exchange recibe el mensaje. El único indicio es que la queue permanece vacía aunque se publique.

La forma de diagnosticarlo fue comparar las métricas del exchange vs la queue en la management UI de RabbitMQ (`localhost:15672`):

- Exchange `ingest` → `publish_in: 18`, `publish_out: 0`
- Queue `ingest` → `deliver_get: 0`

`publish_out: 0` significa que el exchange no envió nada a ninguna queue (ni a otro exchange). Ahí se confirmó que el problema era de routing, no de consumo.

### Cuándo `publish_out` es 0 y cuándo no

`publish_out` en un exchange cuenta únicamente los mensajes que el exchange reenvió a **otro exchange** (exchange-to-exchange routing). NO cuenta los mensajes entregados a queues. Así que `publish_out: 0` con `publish_in: 18` no necesariamente es un bug — solo significa que no hay exchange-to-exchange routing. El indicador real es `deliver_get` en la queue.

### Regla para recordar

> En un exchange `direct` de RabbitMQ, el mensaje solo llega a la queue si `routing_key del mensaje == binding_key del binding`. Symfony Messenger usa routing key vacío por defecto. Siempre configurar `default_publish_routing_key` cuando el exchange es `direct`.
