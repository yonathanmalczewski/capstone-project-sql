/* =============================================================================
   PROYECTO CAPSTONE - Análisis Exploratorio de Datos (EDA) en PostgreSQL
   Archivo : estructura.sql
   Autor   : Yonathan Malczewski
   Dataset : Brazilian E-Commerce Public Dataset by Olist (Kaggle)
             https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce
   Motor   : PostgreSQL 18 (compatible con PostgreSQL 14+)

   QUÉ HACE ESTE SCRIPT (pipeline de 6 etapas)
     0. La base capstone_project la crea crear_bd.sql (setup automático).
     1. Crear un esquema "staging" con tablas crudas (todas las columnas TEXT).
     2. Cargar los CSV de Kaggle en staging con COPY.
     3. Diagnosticar la calidad del dato (nulos, duplicados, huérfanos).
     4. Limpiar y transformar hacia el modelo final con tipos correctos
        (DATE, TIMESTAMP, NUMERIC, SMALLINT) usando COALESCE, NULLIF, CASE.
     5. Crear índices solo donde el análisis los necesita.
     6. Validar conteos antes/después para detectar pérdidas o duplicaciones.

   POR QUÉ UN STAGING EN TEXTO
     Si cargamos el CSV directo en columnas NUMERIC o DATE, una sola fila mal
     formada aborta toda la carga. Cargando primero todo como TEXT, el COPY
     nunca falla por tipos, y la conversión queda explícita y auditable en la
     etapa 4 (patrón ELT habitual en equipos de datos).

   ANTES DE EJECUTAR
     a) Descargar el dataset de Kaggle y descomprimirlo en una carpeta (por
        ejemplo C:/capstone_data/). Se usan 7 de los 9 CSV (no hacen falta
        geolocation ni sellers). Si usás otra carpeta, cambiá la ÚNICA línea
        de configuración que está justo debajo de este encabezado.
     b) Opción automática (recomendada), desde la carpeta del repositorio:
            psql -U postgres -f crear_bd.sql
        crea la base si no existe y ejecuta este archivo de una sola pasada.
     c) Opción manual con pgAdmin: crear la base (ver sección 0), abrir el
        Query Tool sobre capstone_project y ejecutar este archivo (F5).
     El script es re-ejecutable: borra y recrea todo en cada corrida.
   ============================================================================= */
-- Codificacion UTF-8 (evita errores de acentos si se ejecuta con psql en Windows)
SET client_encoding = 'UTF8';

-- ============================================================================
-- CONFIGURACIÓN: carpeta donde están los CSV  >>> ÚNICA LÍNEA A EDITAR <<<
-- Acepta "/" o "\" y funciona con o sin barra final. Ejemplos:
--   Windows : 'C:/capstone_data/'   o   'C:/Users/<tu_usuario>/Documents/capstone_data/'
--   macOS   : '/Users/<tu_usuario>/capstone_data/'
--   Linux   : '/home/<tu_usuario>/capstone_data/'
-- La sección 2 arma la ruta de cada CSV a partir de este valor.
-- ============================================================================
SET capstone.ruta_datos = 'C:/capstone_data/';


/* -----------------------------------------------------------------------------
   0. CONFIGURACIÓN: CREAR LA BASE DE DATOS
   -----------------------------------------------------------------------------
   La creación está AUTOMATIZADA en crear_bd.sql: crea capstone_project solo
   si no existe, se conecta a ella y ejecuta este archivo, todo en un paso:
       psql -U postgres -f crear_bd.sql
   Acá no puede ir activa porque CREATE DATABASE no puede ejecutarse en la
   misma sesión que después crea las tablas (hay que conectarse a la base
   nueva), y en una segunda corrida fallaría con "la base ya existe".
   Para la opción manual con pgAdmin, ejecutá esta línea (sin los "--")
   conectado a la base "postgres", antes que el resto del archivo:
   ----------------------------------------------------------------------------- */
-- CREATE DATABASE capstone_project;


/* -----------------------------------------------------------------------------
   1. STAGING: TABLAS CRUDAS
   -----------------------------------------------------------------------------
   Reflejan 1:1 las columnas de cada CSV (incluso los errores de tipeo
   originales, como "lenght"), para que COPY las cargue sin transformar nada.
   ----------------------------------------------------------------------------- */
DROP SCHEMA IF EXISTS staging CASCADE;
CREATE SCHEMA staging;

CREATE TABLE staging.clientes_raw (
    customer_id               TEXT,
    customer_unique_id        TEXT,
    customer_zip_code_prefix  TEXT,
    customer_city             TEXT,
    customer_state            TEXT
);

CREATE TABLE staging.pedidos_raw (
    order_id                       TEXT,
    customer_id                    TEXT,
    order_status                   TEXT,
    order_purchase_timestamp       TEXT,
    order_approved_at              TEXT,
    order_delivered_carrier_date   TEXT,
    order_delivered_customer_date  TEXT,
    order_estimated_delivery_date  TEXT
);

CREATE TABLE staging.detalle_pedidos_raw (
    order_id             TEXT,
    order_item_id        TEXT,
    product_id           TEXT,
    seller_id            TEXT,
    shipping_limit_date  TEXT,
    price                TEXT,
    freight_value        TEXT
);

CREATE TABLE staging.productos_raw (
    product_id                  TEXT,
    product_category_name       TEXT,
    product_name_lenght         TEXT,
    product_description_lenght  TEXT,
    product_photos_qty          TEXT,
    product_weight_g            TEXT,
    product_length_cm           TEXT,
    product_height_cm           TEXT,
    product_width_cm            TEXT
);

CREATE TABLE staging.categorias_raw (
    product_category_name          TEXT,
    product_category_name_english  TEXT
);

CREATE TABLE staging.pagos_raw (
    order_id              TEXT,
    payment_sequential    TEXT,
    payment_type          TEXT,
    payment_installments  TEXT,
    payment_value         TEXT
);

CREATE TABLE staging.resenas_raw (
    review_id                TEXT,
    order_id                 TEXT,
    review_score             TEXT,
    review_comment_title     TEXT,
    review_comment_message   TEXT,
    review_creation_date     TEXT,
    review_answer_timestamp  TEXT
);


/* -----------------------------------------------------------------------------
   2. CARGA DE LOS CSV (COPY)
   -----------------------------------------------------------------------------
   COPY lee el archivo desde el SERVIDOR PostgreSQL. En una instalación local
   (pgAdmin + PostgreSQL en la misma PC) funciona directo. Si aparece
   "permission denied", el servicio de Postgres no puede leer esa carpeta:
   dale permiso de lectura a "Todos" sobre la carpeta de los CSV (clic
   derecho > Propiedades > Seguridad) o movela a la raíz del disco
   (C:/capstone_data/). FORMAT csv respeta comillas y saltos de línea dentro
   de los comentarios de las reseñas.

   Por qué un bloque DO: COPY solo acepta la ruta como texto fijo, no como
   variable. El bloque arma cada ruta a partir de la configuración del inicio
   (capstone.ruta_datos) y la ejecuta con EXECUTE. Así la ruta se escribe una
   sola vez y no hay que editar 7 líneas al cambiar de carpeta o de PC.
   ----------------------------------------------------------------------------- */
DO $$
DECLARE
    ruta TEXT := current_setting('capstone.ruta_datos', true);
BEGIN
    -- Error claro si se ejecuta esta sección sin haber corrido la configuración
    IF ruta IS NULL OR TRIM(ruta) = '' THEN
        RAISE EXCEPTION 'Falta la ruta de los CSV. Ejecutá primero la línea SET capstone.ruta_datos = ''...''; del inicio de estructura.sql';
    END IF;

    -- Normaliza la ruta: "\" de Windows pasa a "/" y se asegura la barra final
    ruta := RTRIM(REPLACE(TRIM(ruta), '\', '/'), '/') || '/';

    EXECUTE format('COPY staging.clientes_raw        FROM %L WITH (FORMAT csv, HEADER true, ENCODING ''UTF8'')', ruta || 'olist_customers_dataset.csv');
    EXECUTE format('COPY staging.pedidos_raw         FROM %L WITH (FORMAT csv, HEADER true, ENCODING ''UTF8'')', ruta || 'olist_orders_dataset.csv');
    EXECUTE format('COPY staging.detalle_pedidos_raw FROM %L WITH (FORMAT csv, HEADER true, ENCODING ''UTF8'')', ruta || 'olist_order_items_dataset.csv');
    EXECUTE format('COPY staging.productos_raw       FROM %L WITH (FORMAT csv, HEADER true, ENCODING ''UTF8'')', ruta || 'olist_products_dataset.csv');
    EXECUTE format('COPY staging.categorias_raw      FROM %L WITH (FORMAT csv, HEADER true, ENCODING ''UTF8'')', ruta || 'product_category_name_translation.csv');
    EXECUTE format('COPY staging.pagos_raw           FROM %L WITH (FORMAT csv, HEADER true, ENCODING ''UTF8'')', ruta || 'olist_order_payments_dataset.csv');
    EXECUTE format('COPY staging.resenas_raw         FROM %L WITH (FORMAT csv, HEADER true, ENCODING ''UTF8'')', ruta || 'olist_order_reviews_dataset.csv');

    RAISE NOTICE 'CSV cargados desde %', ruta;

-- Errores frecuentes al cargar: se relanzan con una pista de cómo resolverlos.
-- SQLERRM conserva el mensaje original, que incluye la ruta del archivo.
EXCEPTION
    WHEN undefined_file THEN
        RAISE EXCEPTION '%', SQLERRM
            USING HINT = 'Revisá la línea SET capstone.ruta_datos del inicio de estructura.sql: tiene que apuntar a la carpeta donde descomprimiste los CSV de Kaggle.';
    WHEN insufficient_privilege THEN
        RAISE EXCEPTION '%', SQLERRM
            USING HINT = 'El servicio de PostgreSQL no puede leer esa carpeta: usá C:/capstone_data/ o dale permiso de lectura a "Todos" (ver README, sección 9).';
END $$;


/* -----------------------------------------------------------------------------
   3. DIAGNÓSTICO DE CALIDAD (antes de limpiar)
   -----------------------------------------------------------------------------
   Regla de oro del curso: definir explícitamente qué hacemos con cada dato
   faltante. Primero hay que medirlo. COUNT(*) - COUNT(col) cuenta los NULL;
   NULLIF(TRIM(col), '') convierte los textos vacíos en NULL para que también
   se cuenten (en un CSV, "vacío" y "nulo" llegan distinto).
   ----------------------------------------------------------------------------- */

-- 3.1 Reporte de nulos en columnas críticas (precios, fechas, categorías)
SELECT 'pedidos'   AS tabla, 'fecha_compra'        AS columna, COUNT(*) - COUNT(NULLIF(TRIM(order_purchase_timestamp), ''))      AS nulos, COUNT(*) AS filas FROM staging.pedidos_raw
UNION ALL
SELECT 'pedidos',   'fecha_aprobacion',   COUNT(*) - COUNT(NULLIF(TRIM(order_approved_at), '')),             COUNT(*) FROM staging.pedidos_raw
UNION ALL
SELECT 'pedidos',   'fecha_entrega',      COUNT(*) - COUNT(NULLIF(TRIM(order_delivered_customer_date), '')), COUNT(*) FROM staging.pedidos_raw
UNION ALL
SELECT 'detalle',   'precio',             COUNT(*) - COUNT(NULLIF(TRIM(price), '')),                         COUNT(*) FROM staging.detalle_pedidos_raw
UNION ALL
SELECT 'detalle',   'flete',              COUNT(*) - COUNT(NULLIF(TRIM(freight_value), '')),                 COUNT(*) FROM staging.detalle_pedidos_raw
UNION ALL
SELECT 'productos', 'categoria',          COUNT(*) - COUNT(NULLIF(TRIM(product_category_name), '')),         COUNT(*) FROM staging.productos_raw
UNION ALL
SELECT 'productos', 'peso_g',             COUNT(*) - COUNT(NULLIF(TRIM(product_weight_g), '')),              COUNT(*) FROM staging.productos_raw
UNION ALL
SELECT 'productos', 'cantidad_fotos',     COUNT(*) - COUNT(NULLIF(TRIM(product_photos_qty), '')),            COUNT(*) FROM staging.productos_raw;
-- Resultado esperado: 0 nulos en precio/flete/fecha_compra; 160 pedidos sin
-- aprobación; 2.965 sin fecha de entrega; 610 productos sin categoría.

-- 3.2 ¿customer_id identifica a una persona? NO: Olist genera un customer_id
-- nuevo por cada pedido. La persona real es customer_unique_id. Si
-- agrupáramos por customer_id, un cliente que compró 3 veces aparecería como
-- 3 clientes distintos y el "Top clientes" y la tasa de recompra saldrían mal.
SELECT COUNT(DISTINCT customer_id)        AS customer_id_distintos,
       COUNT(DISTINCT customer_unique_id) AS personas_reales
FROM staging.clientes_raw;

-- 3.3 Largo de los códigos postales. En la versión de Kaggle todos tienen 5
-- dígitos, pero si el CSV se abre y se guarda con Excel, los que empiezan con
-- 0 pierden ese cero ('09790' => '9790'). Lo verificamos y lo corregimos igual.
SELECT LENGTH(customer_zip_code_prefix) AS largo, COUNT(*) AS clientes
FROM staging.clientes_raw
GROUP BY LENGTH(customer_zip_code_prefix);

-- 3.4 Categorías de productos sin traducción al inglés
SELECT DISTINCT p.product_category_name
FROM staging.productos_raw p
LEFT JOIN staging.categorias_raw c
       ON c.product_category_name = p.product_category_name
WHERE p.product_category_name IS NOT NULL
  AND c.product_category_name IS NULL;

-- 3.5 Pedidos sin ningún ítem (casi todos cancelados/no disponibles). Un
-- INNER JOIN los haría desaparecer "en silencio"; lo documentamos.
SELECT p.order_status, COUNT(*) AS pedidos_sin_items
FROM staging.pedidos_raw p
LEFT JOIN staging.detalle_pedidos_raw d ON d.order_id = p.order_id
WHERE d.order_id IS NULL
GROUP BY p.order_status
ORDER BY pedidos_sin_items DESC;

-- 3.6 Reseñas: review_id NO es único por sí solo (se repite entre pedidos),
-- y hay pedidos con más de una reseña. La clave correcta es (review_id, order_id).
SELECT COUNT(*)                                   AS filas,
       COUNT(DISTINCT review_id)                  AS review_id_distintos,
       COUNT(DISTINCT (review_id, order_id))      AS combinaciones_unicas,
       COUNT(DISTINCT order_id)                   AS pedidos_con_resena
FROM staging.resenas_raw;

-- 3.7 Valores fuera de dominio en pagos (tipo 'not_defined', 0 cuotas)
SELECT payment_type, COUNT(*) AS pagos,
       SUM(CASE WHEN payment_installments = '0' THEN 1 ELSE 0 END) AS con_cero_cuotas
FROM staging.pagos_raw
GROUP BY payment_type
ORDER BY pagos DESC;


/* -----------------------------------------------------------------------------
   4. LIMPIEZA Y TRANSFORMACIÓN AL MODELO FINAL
   -----------------------------------------------------------------------------
   Modelo relacional (ver diagrama ER en el README):
       categorias 1─N productos 1─N detalle_pedidos N─1 pedidos N─1 clientes
                                                    pedidos 1─N pagos
                                                    pedidos 1─N resenas
   Todo se ejecuta en UNA transacción: si cualquier paso falla (por ejemplo un
   CHECK que detecta un precio negativo) se hace ROLLBACK y no queda la base a
   medio cargar.
   ----------------------------------------------------------------------------- */
BEGIN;

DROP TABLE IF EXISTS resenas, pagos, detalle_pedidos, pedidos, productos, categorias, clientes CASCADE;

-- 4.1 CATEGORIAS --------------------------------------------------------------
-- Se agregan las categorías que existen en productos pero no en el archivo de
-- traducción (pc_gamer y otra), más una categoría 'sin_categoria' para los
-- 610 productos sin dato: preferimos no perder esas ventas del total.
-- es_tecnologia marca la vertical que la dirección quiere evaluar.
CREATE TABLE categorias (
    categoria_id   SERIAL       PRIMARY KEY,
    nombre_pt      VARCHAR(60)  NOT NULL UNIQUE,
    nombre_en      VARCHAR(60)  NOT NULL,
    es_tecnologia  BOOLEAN      NOT NULL DEFAULT FALSE
);

INSERT INTO categorias (nombre_pt, nombre_en, es_tecnologia)
SELECT todas.nombre_pt,
       -- Si falta la traducción, usamos el nombre original en vez de dejar NULL
       COALESCE(NULLIF(TRIM(t.product_category_name_english), ''), todas.nombre_pt) AS nombre_en,
       -- Vertical Tecnología: informática, telefonía, electrónica, gaming, audio y foto
       CASE WHEN todas.nombre_pt IN ('informatica_acessorios', 'pcs', 'pc_gamer',
                                     'telefonia', 'telefonia_fixa', 'eletronicos',
                                     'tablets_impressao_imagem', 'consoles_games',
                                     'audio', 'cine_foto')
            THEN TRUE ELSE FALSE END AS es_tecnologia
FROM (
    -- UNION (no UNION ALL) para quedarnos con cada nombre una sola vez
    SELECT NULLIF(TRIM(product_category_name), '') AS nombre_pt FROM staging.categorias_raw
    UNION
    SELECT COALESCE(NULLIF(TRIM(product_category_name), ''), 'sin_categoria') FROM staging.productos_raw
) AS todas
LEFT JOIN staging.categorias_raw t
       ON TRIM(t.product_category_name) = todas.nombre_pt
WHERE todas.nombre_pt IS NOT NULL
ORDER BY todas.nombre_pt;   -- orden fijo: así los categoria_id (SERIAL) salen iguales en cada carga

-- 4.2 CLIENTES ----------------------------------------------------------------
-- Clave = customer_unique_id (la persona). Como una misma persona puede haber
-- comprado desde distintas direcciones, conservamos la del pedido MÁS RECIENTE
-- con DISTINCT ON (extensión de PostgreSQL muy útil para "el último registro").
CREATE TABLE clientes (
    cliente_id     CHAR(32)     PRIMARY KEY,
    codigo_postal  CHAR(5)      NOT NULL,
    ciudad         VARCHAR(60)  NOT NULL,
    estado         CHAR(2)      NOT NULL
);

INSERT INTO clientes (cliente_id, codigo_postal, ciudad, estado)
SELECT DISTINCT ON (c.customer_unique_id)
       c.customer_unique_id,
       LPAD(TRIM(c.customer_zip_code_prefix), 5, '0'),   -- garantiza 5 dígitos aunque se pierda el 0 inicial
       INITCAP(TRIM(c.customer_city)),                    -- 'sao paulo' => 'Sao Paulo'
       UPPER(TRIM(c.customer_state))
FROM staging.clientes_raw c
JOIN staging.pedidos_raw p ON p.customer_id = c.customer_id
ORDER BY c.customer_unique_id, p.order_purchase_timestamp::TIMESTAMP DESC, c.customer_id;  -- customer_id desempata pedidos del mismo segundo

-- 4.3 PRODUCTOS ---------------------------------------------------------------
-- Decisiones sobre faltantes:
--   * categoría NULL           => 'sin_categoria' (COALESCE), para no perder ventas.
--   * cantidad de fotos NULL   => 0 (COALESCE): si no hay dato, no hay fotos cargadas.
--   * peso = 0 g               => NULL (NULLIF): un producto no puede pesar 0; es
--                                 un error de carga, y un 0 sesgaría los promedios.
--   * peso/medidas NULL        => se dejan NULL: "desconocido" NO es cero.
CREATE TABLE productos (
    producto_id     CHAR(32)  PRIMARY KEY,
    categoria_id    INTEGER   NOT NULL REFERENCES categorias (categoria_id),
    cantidad_fotos  SMALLINT  NOT NULL DEFAULT 0 CHECK (cantidad_fotos >= 0),
    peso_g          INTEGER   CHECK (peso_g > 0),
    largo_cm        SMALLINT,
    alto_cm         SMALLINT,
    ancho_cm        SMALLINT
);

INSERT INTO productos (producto_id, categoria_id, cantidad_fotos, peso_g, largo_cm, alto_cm, ancho_cm)
SELECT TRIM(p.product_id),
       cat.categoria_id,
       COALESCE(NULLIF(TRIM(p.product_photos_qty), '')::SMALLINT, 0),
       NULLIF(NULLIF(TRIM(p.product_weight_g), '')::INTEGER, 0),
       NULLIF(TRIM(p.product_length_cm), '')::SMALLINT,
       NULLIF(TRIM(p.product_height_cm), '')::SMALLINT,
       NULLIF(TRIM(p.product_width_cm), '')::SMALLINT
FROM staging.productos_raw p
JOIN categorias cat
  ON cat.nombre_pt = COALESCE(NULLIF(TRIM(p.product_category_name), ''), 'sin_categoria');

-- 4.4 PEDIDOS -----------------------------------------------------------------
-- * Los textos se convierten a TIMESTAMP; la fecha estimada siempre viene a
--   las 00:00:00, así que su tipo correcto es DATE.
-- * Se traducen los estados para que los reportes sean legibles.
-- * fecha_entrega NULL se CONSERVA: significa "todavía no entregado" (o
--   cancelado); imputarle una fecha inventaría tiempos de entrega falsos.
-- * entregado_tarde se calcula con CASE y queda NULL cuando no hay entrega
--   (incluye 8 pedidos 'delivered' sin fecha, una inconsistencia del origen).
CREATE TABLE pedidos (
    pedido_id               CHAR(32)     PRIMARY KEY,
    cliente_id              CHAR(32)     NOT NULL REFERENCES clientes (cliente_id),
    estado_pedido           VARCHAR(15)  NOT NULL,
    fecha_compra            TIMESTAMP    NOT NULL,
    fecha_aprobacion        TIMESTAMP,
    fecha_despacho          TIMESTAMP,
    fecha_entrega           TIMESTAMP,
    fecha_entrega_estimada  DATE         NOT NULL,
    entregado_tarde         BOOLEAN,
    CHECK (fecha_entrega IS NULL OR fecha_entrega >= fecha_compra)
);

INSERT INTO pedidos (pedido_id, cliente_id, estado_pedido, fecha_compra, fecha_aprobacion,
                     fecha_despacho, fecha_entrega, fecha_entrega_estimada, entregado_tarde)
SELECT TRIM(p.order_id),
       c.customer_unique_id,                             -- de customer_id (por pedido) a la persona
       CASE LOWER(TRIM(p.order_status))
            WHEN 'delivered'   THEN 'entregado'
            WHEN 'shipped'     THEN 'enviado'
            WHEN 'canceled'    THEN 'cancelado'
            WHEN 'unavailable' THEN 'no_disponible'
            WHEN 'invoiced'    THEN 'facturado'
            WHEN 'processing'  THEN 'en_proceso'
            WHEN 'approved'    THEN 'aprobado'
            WHEN 'created'     THEN 'creado'
            ELSE 'desconocido'
       END,
       NULLIF(TRIM(p.order_purchase_timestamp), '')::TIMESTAMP,
       NULLIF(TRIM(p.order_approved_at), '')::TIMESTAMP,
       NULLIF(TRIM(p.order_delivered_carrier_date), '')::TIMESTAMP,
       NULLIF(TRIM(p.order_delivered_customer_date), '')::TIMESTAMP,
       NULLIF(TRIM(p.order_estimated_delivery_date), '')::DATE,
       CASE
            WHEN NULLIF(TRIM(p.order_delivered_customer_date), '') IS NULL THEN NULL
            WHEN p.order_delivered_customer_date::DATE > p.order_estimated_delivery_date::DATE THEN TRUE
            ELSE FALSE
       END
FROM staging.pedidos_raw p
JOIN staging.clientes_raw c ON c.customer_id = p.customer_id;

-- 4.5 DETALLE_PEDIDOS (ítems) -------------------------------------------------
-- Precios a NUMERIC(10,2): nunca FLOAT para dinero (FLOAT redondea mal los
-- centavos). El flete usa COALESCE(…, 0) como defensa: si en una recarga futura
-- llegara vacío, lo tratamos como envío gratis en vez de anular el total.
-- CHECK (precio > 0) hace que la transacción falle si entra un precio inválido.
CREATE TABLE detalle_pedidos (
    pedido_id           CHAR(32)       NOT NULL REFERENCES pedidos (pedido_id),
    item_nro            SMALLINT       NOT NULL,
    producto_id         CHAR(32)       NOT NULL REFERENCES productos (producto_id),
    vendedor_id         CHAR(32)       NOT NULL,
    fecha_limite_envio  TIMESTAMP      NOT NULL,
    precio              NUMERIC(10,2)  NOT NULL CHECK (precio > 0),
    flete               NUMERIC(10,2)  NOT NULL DEFAULT 0 CHECK (flete >= 0),
    PRIMARY KEY (pedido_id, item_nro)
);

INSERT INTO detalle_pedidos (pedido_id, item_nro, producto_id, vendedor_id, fecha_limite_envio, precio, flete)
SELECT TRIM(order_id),
       order_item_id::SMALLINT,
       TRIM(product_id),
       TRIM(seller_id),
       shipping_limit_date::TIMESTAMP,
       NULLIF(TRIM(price), '')::NUMERIC(10,2),
       COALESCE(NULLIF(TRIM(freight_value), '')::NUMERIC(10,2), 0)
FROM staging.detalle_pedidos_raw
WHERE NULLIF(TRIM(price), '') IS NOT NULL;   -- un ítem sin precio no es una venta analizable

-- 4.6 PAGOS -------------------------------------------------------------------
-- * 'not_defined' y cualquier valor inesperado => 'no_definido' (CASE).
-- * 0 cuotas no existe: un pago en 0 cuotas es un pago en 1 cuota.
--   NULLIF(…, 0) lo vuelve NULL y COALESCE(…, 1) lo corrige.
CREATE TABLE pagos (
    pedido_id  CHAR(32)       NOT NULL REFERENCES pedidos (pedido_id),
    secuencia  SMALLINT       NOT NULL,
    tipo_pago  VARCHAR(20)    NOT NULL,
    cuotas     SMALLINT       NOT NULL CHECK (cuotas >= 1),
    monto      NUMERIC(10,2)  NOT NULL CHECK (monto >= 0),
    PRIMARY KEY (pedido_id, secuencia)
);

INSERT INTO pagos (pedido_id, secuencia, tipo_pago, cuotas, monto)
SELECT TRIM(order_id),
       payment_sequential::SMALLINT,
       CASE TRIM(payment_type)
            WHEN 'credit_card' THEN 'tarjeta_credito'
            WHEN 'debit_card'  THEN 'tarjeta_debito'
            WHEN 'boleto'      THEN 'boleto'
            WHEN 'voucher'     THEN 'voucher'
            ELSE 'no_definido'
       END,
       COALESCE(NULLIF(NULLIF(TRIM(payment_installments), '')::SMALLINT, 0), 1),
       COALESCE(NULLIF(TRIM(payment_value), '')::NUMERIC(10,2), 0)
FROM staging.pagos_raw;

-- 4.7 RESENAS -----------------------------------------------------------------
-- Guardamos solo lo necesario para el análisis (puntaje y si dejó comentario);
-- el texto libre no se analiza en este proyecto.
CREATE TABLE resenas (
    resena_id         CHAR(32)  NOT NULL,
    pedido_id         CHAR(32)  NOT NULL REFERENCES pedidos (pedido_id),
    puntaje           SMALLINT  NOT NULL CHECK (puntaje BETWEEN 1 AND 5),
    tiene_comentario  BOOLEAN   NOT NULL,
    fecha_resena      DATE      NOT NULL,
    PRIMARY KEY (resena_id, pedido_id)
);

INSERT INTO resenas (resena_id, pedido_id, puntaje, tiene_comentario, fecha_resena)
SELECT TRIM(review_id),
       TRIM(order_id),
       review_score::SMALLINT,
       NULLIF(TRIM(review_comment_message), '') IS NOT NULL,
       review_creation_date::DATE
FROM staging.resenas_raw
WHERE NULLIF(TRIM(review_score), '') IS NOT NULL;

COMMIT;


/* -----------------------------------------------------------------------------
   5. ÍNDICES
   -----------------------------------------------------------------------------
   Las PRIMARY KEY ya crean su índice. Agregamos SOLO las columnas que el
   análisis usa en JOIN o WHERE de forma repetida. Indexar todo ralentiza la
   carga y ocupa espacio sin beneficio (trampa #3 del analista junior).
   ----------------------------------------------------------------------------- */
CREATE INDEX idx_pedidos_cliente        ON pedidos (cliente_id);          -- JOIN clientes-pedidos
CREATE INDEX idx_pedidos_fecha_compra   ON pedidos (fecha_compra);        -- filtros por período
CREATE INDEX idx_detalle_producto       ON detalle_pedidos (producto_id); -- JOIN detalle-productos
CREATE INDEX idx_productos_categoria    ON productos (categoria_id);      -- JOIN productos-categorias
CREATE INDEX idx_resenas_pedido         ON resenas (pedido_id);           -- JOIN pedidos-reseñas

-- Actualiza las estadísticas para que el planificador elija bien los planes.
ANALYZE;


/* -----------------------------------------------------------------------------
   6. VALIDACIÓN POST-CARGA
   -----------------------------------------------------------------------------
   Trampa #1 del curso: "verificá el conteo de filas antes y después". Si una
   tabla final tiene MÁS filas que su origen, un JOIN duplicó registros; si
   tiene MENOS, se perdieron. Las únicas diferencias esperadas son las que
   explicamos (clientes: de 99.441 customer_id a 96.096 personas).
   ----------------------------------------------------------------------------- */
SELECT 'clientes'        AS tabla, (SELECT COUNT(DISTINCT customer_unique_id) FROM staging.clientes_raw) AS filas_origen, (SELECT COUNT(*) FROM clientes)        AS filas_final
UNION ALL SELECT 'categorias',      (SELECT COUNT(*) FROM staging.categorias_raw),      (SELECT COUNT(*) FROM categorias)
UNION ALL SELECT 'productos',       (SELECT COUNT(*) FROM staging.productos_raw),       (SELECT COUNT(*) FROM productos)
UNION ALL SELECT 'pedidos',         (SELECT COUNT(*) FROM staging.pedidos_raw),         (SELECT COUNT(*) FROM pedidos)
UNION ALL SELECT 'detalle_pedidos', (SELECT COUNT(*) FROM staging.detalle_pedidos_raw), (SELECT COUNT(*) FROM detalle_pedidos)
UNION ALL SELECT 'pagos',           (SELECT COUNT(*) FROM staging.pagos_raw),           (SELECT COUNT(*) FROM pagos)
UNION ALL SELECT 'resenas',         (SELECT COUNT(*) FROM staging.resenas_raw),         (SELECT COUNT(*) FROM resenas);
-- categorias final = origen + 3 (pc_gamer, portateis_cozinha…, sin_categoria).

-- Control final: no deben quedar nulos en las columnas críticas del análisis.
SELECT
    (SELECT COUNT(*) FROM detalle_pedidos WHERE precio IS NULL OR flete IS NULL) AS precios_nulos,
    (SELECT COUNT(*) FROM pedidos WHERE fecha_compra IS NULL)                    AS fechas_compra_nulas,
    (SELECT COUNT(*) FROM productos WHERE categoria_id IS NULL)                  AS productos_sin_categoria;
-- Esperado: 0 | 0 | 0  => datos listos para analisis.sql
