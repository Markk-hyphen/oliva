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
