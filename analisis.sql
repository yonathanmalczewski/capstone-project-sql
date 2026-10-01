/* =============================================================================
   PROYECTO CAPSTONE - Análisis Exploratorio de Datos (EDA) en PostgreSQL
   Archivo : analisis.sql
   Autor   : Yonathan Malczewski
   Requiere: base capstone_project cargada (crear_bd.sql o estructura.sql).

   PROBLEMA DE NEGOCIO
     La dirección de Olist (marketplace brasileño) evalúa invertir más en su
     vertical de Tecnología (informática, telefonía, electrónica, gaming,
     audio y foto). Antes de decidir necesita entender:
       - quiénes compran y cuánto valen los mejores clientes,
       - cómo evolucionan las ventas y qué peso tiene tecnología,
       - qué productos/categorías no rotan,
       - cuándo compran y cuándo se pierden ventas,
       - si los clientes vuelven, y qué los hace volver o irse,
       - cómo pagan las compras de tecnología.

   CONVENCIONES (aplican a todas las consultas)
     * Venta válida  = pedido cuyo estado NO es 'cancelado' ni 'no_disponible'.
       Los cancelados se analizan aparte (pregunta 5) porque son ventas perdidas.
     * Facturación   = SUM(precio) de los ítems (valor de la mercadería).
       Gasto cliente = precio + flete (lo que efectivamente pagó el cliente).
     * Moneda: reales brasileños (BRL, R$).
     * Período completo: ene-2017 a ago-2018. 2016 tiene 329 pedidos sueltos
       (prueba de la plataforma) y sep/oct-2018 están incompletos; incluirlos
       en tendencias mensuales mostraría "caídas" que no son reales.
   ============================================================================= */
-- Codificacion UTF-8 (evita errores de acentos si se ejecuta con psql en Windows)
SET client_encoding = 'UTF8';
/* =============================================================================
   PREGUNTA 1 - ¿Quiénes son nuestros 5 mejores clientes por gasto total?
   Técnicas: JOIN de 5 tablas, GROUP BY + SUM, BOOL_OR, RANK() y SUM() OVER().
   ============================================================================= */
-- Agrupamos por cliente_id (= customer_unique_id, la persona real) y NO por el
-- customer_id original del CSV, que cambia en cada pedido: con ese campo un
-- cliente recurrente se partiría en varios "clientes" y nunca llegaría al top.
WITH gasto_por_cliente AS (
    SELECT c.cliente_id,
           c.ciudad,
           c.estado,
           COUNT(DISTINCT p.pedido_id)          AS cantidad_pedidos,
           COUNT(*)                             AS unidades,
           SUM(d.precio + d.flete)              AS gasto_total,
           BOOL_OR(cat.es_tecnologia)           AS compro_tecnologia
    FROM clientes c
    JOIN pedidos         p   ON p.cliente_id    = c.cliente_id
    JOIN detalle_pedidos d   ON d.pedido_id     = p.pedido_id
    JOIN productos       pr  ON pr.producto_id  = d.producto_id
    JOIN categorias      cat ON cat.categoria_id = pr.categoria_id
    WHERE p.estado_pedido NOT IN ('cancelado', 'no_disponible')
    GROUP BY c.cliente_id, c.ciudad, c.estado
)
SELECT RANK() OVER (ORDER BY gasto_total DESC)                   AS puesto,
       LEFT(cliente_id, 8) || '...'                             AS cliente,   -- ID abreviado para el reporte
       ciudad,
       estado,
       cantidad_pedidos,
       unidades,
       gasto_total,
       ROUND(gasto_total / cantidad_pedidos, 2)                 AS ticket_promedio,
       compro_tecnologia,
       -- Peso del cliente sobre la facturación total: la ventana se calcula
       -- sobre TODOS los clientes antes de aplicar el LIMIT.
       ROUND(100 * gasto_total / SUM(gasto_total) OVER (), 3)   AS pct_del_total
FROM gasto_por_cliente
ORDER BY gasto_total DESC, cliente_id   -- cliente_id solo desempata, para un orden siempre igual
LIMIT 5;


/* =============================================================================
   PREGUNTA 2 - ¿Cómo evolucionan las ventas mes a mes y cuánto aporta Tecnología?
   Técnicas: DATE_TRUNC, TO_CHAR, CASE dentro de SUM, LAG() y SUM() OVER (acumulado).
   ============================================================================= */
-- 2.a Serie mensual: facturación, variación contra el mes anterior,
--     acumulado del período y participación de la vertical Tecnología.
WITH ventas_mensuales AS (
    SELECT DATE_TRUNC('month', p.fecha_compra)::DATE                       AS mes,
           COUNT(DISTINCT p.pedido_id)                                     AS pedidos,
           SUM(d.precio)                                                   AS facturacion,
           SUM(CASE WHEN cat.es_tecnologia THEN d.precio ELSE 0 END)       AS facturacion_tecno
    FROM pedidos p
    JOIN detalle_pedidos d   ON d.pedido_id      = p.pedido_id
    JOIN productos       pr  ON pr.producto_id   = d.producto_id
    JOIN categorias      cat ON cat.categoria_id = pr.categoria_id
    WHERE p.estado_pedido NOT IN ('cancelado', 'no_disponible')
      AND p.fecha_compra >= DATE '2017-01-01'
      AND p.fecha_compra <  DATE '2018-09-01'     -- excluye meses incompletos
    GROUP BY DATE_TRUNC('month', p.fecha_compra)
)
SELECT TO_CHAR(mes, 'YYYY-MM')                                               AS mes,
       pedidos,
       facturacion,
       -- NULLIF evita la división por cero si algún mes anterior no tuviera ventas
       ROUND(100 * (facturacion - LAG(facturacion) OVER w)
                 / NULLIF(LAG(facturacion) OVER w, 0), 1)                    AS var_vs_mes_anterior_pct,
       SUM(facturacion) OVER w                                               AS facturacion_acumulada,
       ROUND(100 * facturacion_tecno / facturacion, 1)                       AS pct_tecnologia
FROM ventas_mensuales
WINDOW w AS (ORDER BY mes)
ORDER BY mes;

-- 2.b Crecimiento interanual comparable: ene-ago 2018 vs ene-ago 2017.
-- Comparamos los mismos 8 meses para que la estacionalidad (ej. Black Friday
-- en noviembre) no infle la comparación.
SELECT CASE WHEN cat.es_tecnologia THEN 'Tecnología' ELSE 'Resto' END                              AS vertical,
       SUM(CASE WHEN EXTRACT(YEAR FROM p.fecha_compra) = 2017 THEN d.precio ELSE 0 END)           AS ene_ago_2017,
       SUM(CASE WHEN EXTRACT(YEAR FROM p.fecha_compra) = 2018 THEN d.precio ELSE 0 END)           AS ene_ago_2018,
       ROUND(100 * (SUM(CASE WHEN EXTRACT(YEAR FROM p.fecha_compra) = 2018 THEN d.precio ELSE 0 END)
                  / NULLIF(SUM(CASE WHEN EXTRACT(YEAR FROM p.fecha_compra) = 2017 THEN d.precio ELSE 0 END), 0)
                  - 1), 1)                                                                          AS crecimiento_pct
FROM pedidos p
JOIN detalle_pedidos d   ON d.pedido_id      = p.pedido_id
JOIN productos       pr  ON pr.producto_id   = d.producto_id
JOIN categorias      cat ON cat.categoria_id = pr.categoria_id
WHERE p.estado_pedido NOT IN ('cancelado', 'no_disponible')
  AND EXTRACT(YEAR  FROM p.fecha_compra) IN (2017, 2018)
  AND EXTRACT(MONTH FROM p.fecha_compra) BETWEEN 1 AND 8
GROUP BY CASE WHEN cat.es_tecnologia THEN 'Tecnología' ELSE 'Resto' END;


/* =============================================================================
   PREGUNTA 3 - ¿Cuáles son los 3 productos de Tecnología menos vendidos?
   Técnicas: LEFT JOIN (para no perder productos sin ventas), COUNT, CASE,
             desempate explícito.
   ============================================================================= */
-- Partimos de PRODUCTOS con LEFT JOIN: un INNER JOIN eliminaría justamente a
-- los productos que nunca se vendieron (o solo en pedidos cancelados), que son
-- los que más nos interesan acá. La condición de estado va en el ON y no en el
-- WHERE: si fuera en el WHERE, convertiría el LEFT JOIN en un INNER JOIN.
WITH ventas_por_producto AS (
    SELECT pr.producto_id,
           cat.nombre_en                          AS categoria,
           COUNT(p.pedido_id)                     AS unidades_vendidas,
           -- solo sumamos el precio de ítems de pedidos válidos; sin ventas => 0
           COALESCE(SUM(CASE WHEN p.pedido_id IS NOT NULL THEN d.precio END), 0) AS facturacion,
           MAX(p.fecha_compra)::DATE              AS ultima_venta
    FROM productos pr
    JOIN categorias           cat ON cat.categoria_id = pr.categoria_id
    LEFT JOIN detalle_pedidos d   ON d.producto_id    = pr.producto_id
    LEFT JOIN pedidos         p   ON p.pedido_id      = d.pedido_id
                                 AND p.estado_pedido NOT IN ('cancelado', 'no_disponible')
    WHERE cat.es_tecnologia
    GROUP BY pr.producto_id, cat.nombre_en
)
-- 3.a Los 3 menos vendidos. Hay cientos de empates en 0-1 unidad, así que el
--     desempate es de negocio: menor facturación y venta más antigua primero
--     (el candidato más claro a "stock muerto" para dar de baja o liquidar).
SELECT LEFT(producto_id, 8) || '...'  AS producto,
       categoria,
       unidades_vendidas,
       facturacion,
       COALESCE(ultima_venta::TEXT, 'sin ventas válidas') AS ultima_venta
FROM ventas_por_producto
ORDER BY unidades_vendidas ASC, facturacion ASC, ultima_venta ASC NULLS FIRST, producto_id  -- último desempate fijo
LIMIT 3;

-- 3.b Como el "top 3 menos vendidos" está lleno de empates, medimos el
--     fenómeno completo: ¿cuánto del catálogo tecnológico casi no rota?
WITH unidades_por_producto AS (
    SELECT pr.producto_id,
           COUNT(p.pedido_id) AS unidades_vendidas
    FROM productos pr
    JOIN categorias           cat ON cat.categoria_id = pr.categoria_id
    LEFT JOIN detalle_pedidos d   ON d.producto_id    = pr.producto_id
    LEFT JOIN pedidos         p   ON p.pedido_id      = d.pedido_id
                                 AND p.estado_pedido NOT IN ('cancelado', 'no_disponible')
    WHERE cat.es_tecnologia
    GROUP BY pr.producto_id
)
SELECT CASE
           WHEN unidades_vendidas = 0             THEN '1. Sin ventas válidas'
           WHEN unidades_vendidas = 1             THEN '2. Una sola unidad'
           WHEN unidades_vendidas BETWEEN 2 AND 5 THEN '3. Entre 2 y 5'
           WHEN unidades_vendidas BETWEEN 6 AND 20 THEN '4. Entre 6 y 20'
           ELSE                                        '5. Más de 20'
       END                                                        AS rotacion,
       COUNT(*)                                                   AS productos,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)         AS pct_catalogo,
       SUM(unidades_vendidas)                                     AS unidades,
       ROUND(100.0 * SUM(unidades_vendidas) / SUM(SUM(unidades_vendidas)) OVER (), 1) AS pct_unidades
FROM unidades_por_producto
GROUP BY 1
ORDER BY 1;


/* =============================================================================
   PREGUNTA 4 - Rankings con RANK(): ¿qué categorías lideran y cuáles son los
                pedidos más valiosos dentro de cada categoría de Tecnología?
   Técnicas: RANK() OVER (ORDER BY), RANK() OVER (PARTITION BY), AVG() OVER.
   ============================================================================= */
-- 4.a Ranking general de categorías por facturación (top 15).
-- RANK() (y no ROW_NUMBER) para que dos categorías empatadas compartan puesto.
WITH facturacion_categoria AS (
    SELECT cat.nombre_en                    AS categoria,
           cat.es_tecnologia,
           COUNT(DISTINCT d.pedido_id)      AS pedidos,
           SUM(d.precio)                    AS facturacion
    FROM detalle_pedidos d
    JOIN pedidos    p   ON p.pedido_id      = d.pedido_id
    JOIN productos  pr  ON pr.producto_id   = d.producto_id
    JOIN categorias cat ON cat.categoria_id = pr.categoria_id
    WHERE p.estado_pedido NOT IN ('cancelado', 'no_disponible')
    GROUP BY cat.nombre_en, cat.es_tecnologia
),
ranking_categorias AS (
    SELECT RANK() OVER (ORDER BY facturacion DESC)                  AS puesto,
           categoria,
           CASE WHEN es_tecnologia THEN 'Tecnología' ELSE '-' END   AS vertical,
           pedidos,
           facturacion,
           ROUND(facturacion / pedidos, 2)                          AS ticket_promedio,
           ROUND(100 * facturacion / SUM(facturacion) OVER (), 1)   AS pct_facturacion
    FROM facturacion_categoria
)
SELECT *
FROM ranking_categorias
WHERE puesto <= 15
ORDER BY puesto;

-- 4.b Composición interna de la vertical Tecnología: ¿qué categorías la
--     sostienen y con qué ticket? Sirve para saber si "Tecnología" en Olist
--     son equipos de alto valor o accesorios de bajo precio.
SELECT RANK() OVER (ORDER BY SUM(d.precio) DESC)                         AS puesto,
       cat.nombre_en                                                     AS categoria,
       COUNT(*)                                                          AS unidades,
       SUM(d.precio)                                                     AS facturacion,
       ROUND(AVG(d.precio), 2)                                           AS precio_promedio_unidad,
       ROUND(100 * SUM(d.precio) / SUM(SUM(d.precio)) OVER (), 1)        AS pct_de_tecnologia
FROM detalle_pedidos d
JOIN pedidos    p   ON p.pedido_id      = d.pedido_id
JOIN productos  pr  ON pr.producto_id   = d.producto_id
JOIN categorias cat ON cat.categoria_id = pr.categoria_id
WHERE cat.es_tecnologia
  AND p.estado_pedido NOT IN ('cancelado', 'no_disponible')
GROUP BY cat.nombre_en
ORDER BY puesto;

-- 4.c Top 3 pedidos por categoría de Tecnología (RANK con PARTITION BY).
-- Primero consolidamos el valor de cada pedido DENTRO de cada categoría: un
-- pedido con 3 ítems de la misma categoría debe contar una sola vez.
WITH valor_pedido_categoria AS (
    SELECT cat.nombre_en     AS categoria,
           d.pedido_id,
           p.fecha_compra::DATE AS fecha,
           COUNT(*)          AS items,
           SUM(d.precio)     AS valor_pedido
    FROM detalle_pedidos d
    JOIN pedidos    p   ON p.pedido_id      = d.pedido_id
    JOIN productos  pr  ON pr.producto_id   = d.producto_id
    JOIN categorias cat ON cat.categoria_id = pr.categoria_id
    WHERE cat.es_tecnologia
      AND p.estado_pedido NOT IN ('cancelado', 'no_disponible')
    GROUP BY cat.nombre_en, d.pedido_id, p.fecha_compra
),
ranking_pedidos AS (
    SELECT categoria,
           RANK() OVER (PARTITION BY categoria ORDER BY valor_pedido DESC)  AS puesto_en_categoria,
           LEFT(pedido_id, 8) || '...'                                     AS pedido,
           fecha,
           items,
           valor_pedido,
           -- Ticket medio de la categoría en la misma fila, para dimensionar
           -- cuántas veces el promedio vale cada pedido top.
           ROUND(AVG(valor_pedido) OVER (PARTITION BY categoria), 2)        AS ticket_promedio_categoria
    FROM valor_pedido_categoria
)
SELECT categoria,
       puesto_en_categoria,
       pedido,
       fecha,
       items,
       valor_pedido,
       ticket_promedio_categoria,
       ROUND(valor_pedido / ticket_promedio_categoria, 1) AS veces_el_ticket_promedio
FROM ranking_pedidos
WHERE puesto_en_categoria <= 3
ORDER BY categoria, puesto_en_categoria, pedido;   -- pedido desempata el orden de visualización de los empates


/* =============================================================================
   PREGUNTA 5 - ¿En qué momento compran los clientes y cuándo perdemos más ventas?
   Técnicas: EXTRACT(HOUR / ISODOW), CASE para franjas, tasas con NULLIF.
   ============================================================================= */
-- 5.a Por franja horaria: volumen, participación y tasa de pérdida.
-- "Venta perdida" = pedido cancelado o no disponible (el cliente quiso comprar
-- y no se concretó). Se usa el universo completo de pedidos del período.
SELECT CASE
           WHEN EXTRACT(HOUR FROM fecha_compra) BETWEEN 0  AND 5  THEN '1. Madrugada (00-06 h)'
           WHEN EXTRACT(HOUR FROM fecha_compra) BETWEEN 6  AND 11 THEN '2. Mañana (06-12 h)'
           WHEN EXTRACT(HOUR FROM fecha_compra) BETWEEN 12 AND 17 THEN '3. Tarde (12-18 h)'
           ELSE                                                        '4. Noche (18-24 h)'
       END                                                                  AS franja_horaria,
       COUNT(*)                                                             AS pedidos,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)                   AS pct_pedidos,
       SUM(CASE WHEN estado_pedido IN ('cancelado', 'no_disponible') THEN 1 ELSE 0 END) AS ventas_perdidas,
       ROUND(100.0 * SUM(CASE WHEN estado_pedido IN ('cancelado', 'no_disponible') THEN 1 ELSE 0 END)
             / NULLIF(COUNT(*), 0), 2)                                      AS tasa_perdida_pct
FROM pedidos
WHERE fecha_compra >= DATE '2017-01-01' AND fecha_compra < DATE '2018-09-01'
GROUP BY 1
ORDER BY 1;

-- 5.b Por día de la semana (ISODOW: 1 = lunes ... 7 = domingo).
SELECT EXTRACT(ISODOW FROM fecha_compra)                                    AS nro_dia,
       CASE EXTRACT(ISODOW FROM fecha_compra)
            WHEN 1 THEN 'Lunes'  WHEN 2 THEN 'Martes' WHEN 3 THEN 'Miércoles'
            WHEN 4 THEN 'Jueves' WHEN 5 THEN 'Viernes' WHEN 6 THEN 'Sábado'
            ELSE 'Domingo'
       END                                                                  AS dia,
       COUNT(*)                                                             AS pedidos,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)                   AS pct_pedidos,
       ROUND(100.0 * SUM(CASE WHEN estado_pedido IN ('cancelado', 'no_disponible') THEN 1 ELSE 0 END)
             / NULLIF(COUNT(*), 0), 2)                                      AS tasa_perdida_pct
FROM pedidos
WHERE fecha_compra >= DATE '2017-01-01' AND fecha_compra < DATE '2018-09-01'
GROUP BY 1, 2
ORDER BY 1;


/* =============================================================================
   PREGUNTA 6 - ¿Cuál es el perfil del cliente leal? ¿Vuelven los clientes?
   Técnicas: CTE en cadena, CASE para segmentar, BOOL_OR, porcentajes con OVER().
   ============================================================================= */
-- 6.a Segmentación por frecuencia de compra. Filtramos por cantidad de pedidos
-- (y no por gasto) porque la lealtad se mide en repetición: un cliente que
-- compró una sola vez algo caro no es leal, es un buen cliente ocasional.
WITH resumen_cliente AS (
    SELECT p.cliente_id,
           COUNT(DISTINCT p.pedido_id)   AS pedidos,
           SUM(d.precio + d.flete)       AS gasto_total
    FROM pedidos p
    JOIN detalle_pedidos d ON d.pedido_id = p.pedido_id
    WHERE p.estado_pedido NOT IN ('cancelado', 'no_disponible')
    GROUP BY p.cliente_id
),
segmentos AS (
    SELECT cliente_id,
           gasto_total,
           CASE WHEN pedidos >= 3 THEN '1. Leal (3+ pedidos)'
                WHEN pedidos = 2  THEN '2. Recurrente (2 pedidos)'
                ELSE                   '3. Única compra'
           END AS segmento
    FROM resumen_cliente
)
SELECT segmento,
       COUNT(*)                                                   AS clientes,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2)         AS pct_clientes,
       SUM(gasto_total)                                           AS gasto_total,
       ROUND(100 * SUM(gasto_total) / SUM(SUM(gasto_total)) OVER (), 2) AS pct_gasto,
       ROUND(AVG(gasto_total), 2)                                 AS gasto_promedio_cliente
FROM segmentos
GROUP BY segmento
ORDER BY segmento;

-- 6.b ¿La primera experiencia define si el cliente vuelve?
-- Tomamos el PRIMER pedido válido de cada cliente (ROW_NUMBER) y cruzamos
-- su puntaje de reseña con si volvió a comprar después. Las reseñas se
-- promedian por pedido ANTES del JOIN: hay pedidos con más de una reseña y
-- unirlos directo duplicaría filas (trampa de la "explosión" en los JOINs).
WITH resena_por_pedido AS (
    SELECT pedido_id, AVG(puntaje) AS puntaje
    FROM resenas
    GROUP BY pedido_id
),
pedidos_numerados AS (
    SELECT p.cliente_id,
           p.pedido_id,
           ROW_NUMBER() OVER (PARTITION BY p.cliente_id ORDER BY p.fecha_compra, p.pedido_id) AS nro_pedido,  -- pedido_id desempata compras hechas en el mismo segundo
           COUNT(*)     OVER (PARTITION BY p.cliente_id)                         AS total_pedidos
    FROM pedidos p
    WHERE p.estado_pedido NOT IN ('cancelado', 'no_disponible')
)
SELECT CASE WHEN r.puntaje >= 4 THEN '1. Primera experiencia buena (4-5)'
            WHEN r.puntaje >= 3 THEN '2. Neutra (3)'
            ELSE                     '3. Mala (1-2)'
       END                                                         AS primera_experiencia,
       COUNT(*)                                                    AS clientes,
       SUM(CASE WHEN pn.total_pedidos > 1 THEN 1 ELSE 0 END)       AS volvieron_a_comprar,
       ROUND(100.0 * SUM(CASE WHEN pn.total_pedidos > 1 THEN 1 ELSE 0 END)
             / COUNT(*), 2)                                        AS tasa_recompra_pct
FROM pedidos_numerados pn
JOIN resena_por_pedido r ON r.pedido_id = pn.pedido_id
WHERE pn.nro_pedido = 1
GROUP BY 1
ORDER BY 1;


/* =============================================================================
   PREGUNTA 7 - ¿Cómo impacta la demora en la entrega en la satisfacción?
                ¿Dónde es peor la experiencia logística en Tecnología?
   Técnicas: aritmética de fechas, CASE por tramos, AVG, JOIN con CTE agregada,
             RANK() para ordenar estados.
   ============================================================================= */
-- 7.a Demora (días reales vs fecha prometida) contra puntaje de reseña.
-- Solo pedidos entregados con fecha de entrega conocida: a los pedidos sin
-- entrega no se les puede medir demora (decisión explícita, no imputamos).
WITH resena_por_pedido AS (
    SELECT pedido_id, AVG(puntaje) AS puntaje
    FROM resenas
    GROUP BY pedido_id
)
SELECT CASE
           WHEN p.fecha_entrega::DATE <= p.fecha_entrega_estimada                 THEN '1. A tiempo o antes'
           WHEN p.fecha_entrega::DATE - p.fecha_entrega_estimada BETWEEN 1 AND 3  THEN '2. 1 a 3 días tarde'
           WHEN p.fecha_entrega::DATE - p.fecha_entrega_estimada BETWEEN 4 AND 10 THEN '3. 4 a 10 días tarde'
           ELSE                                                                        '4. Más de 10 días tarde'
       END                                                               AS cumplimiento,
       COUNT(*)                                                          AS pedidos,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)                AS pct_pedidos,
       ROUND(AVG(r.puntaje), 2)                                          AS puntaje_promedio,
       ROUND(100.0 * SUM(CASE WHEN r.puntaje <= 2 THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_resenas_negativas
FROM pedidos p
JOIN resena_por_pedido r ON r.pedido_id = p.pedido_id
WHERE p.estado_pedido = 'entregado'
  AND p.fecha_entrega IS NOT NULL
GROUP BY 1
ORDER BY 1;

-- 7.b Estados (provincias) con mayor facturación en Tecnología: tiempos de
--     entrega, peso del flete y tasa de demora. Top 10 por facturación.
-- Los ítems se agregan por pedido antes de unir con la logística, para que un
-- pedido de 3 ítems no cuente 3 veces sus días de entrega en el promedio.
WITH pedidos_tecno AS (
    SELECT d.pedido_id,
           SUM(d.precio) AS precio,
           SUM(d.flete)  AS flete
    FROM detalle_pedidos d
    JOIN productos  pr  ON pr.producto_id   = d.producto_id
    JOIN categorias cat ON cat.categoria_id = pr.categoria_id
    WHERE cat.es_tecnologia
    GROUP BY d.pedido_id
),
por_estado AS (
    SELECT c.estado,
           COUNT(*)                                                     AS pedidos,
           SUM(pt.precio)                                               AS facturacion,
           ROUND(100 * SUM(pt.flete) / SUM(pt.precio), 1)               AS flete_sobre_precio_pct,
           ROUND(AVG(p.fecha_entrega::DATE - p.fecha_compra::DATE), 1)  AS dias_entrega_promedio,
           ROUND(100.0 * SUM(CASE WHEN p.entregado_tarde THEN 1 ELSE 0 END)
                 / NULLIF(COUNT(p.entregado_tarde), 0), 1)              AS pct_entregas_tarde
    FROM pedidos_tecno pt
    JOIN pedidos  p ON p.pedido_id  = pt.pedido_id
    JOIN clientes c ON c.cliente_id = p.cliente_id
    WHERE p.estado_pedido NOT IN ('cancelado', 'no_disponible')
    GROUP BY c.estado
)
SELECT *
FROM (
    SELECT RANK() OVER (ORDER BY facturacion DESC) AS puesto, *
    FROM por_estado
) AS ranking_estados
WHERE puesto <= 10
ORDER BY puesto;


/* =============================================================================
   PREGUNTA 8 - ¿Cómo pagan los clientes de Tecnología? (medio de pago y cuotas)
   Técnicas: CTEs que agregan por pedido ANTES de unir (evita explosión N x M),
             CASE, AVG, porcentajes condicionales.
   ============================================================================= */
-- Un pedido puede tener varios ítems Y varios pagos. Unir detalle_pedidos con
-- pagos directamente multiplicaría filas (3 ítems x 2 pagos = 6 filas) e
-- inflaría montos y cuotas. Por eso cada lado se reduce a 1 fila por pedido.
WITH tipo_pedido AS (
    SELECT d.pedido_id,
           CASE WHEN BOOL_OR(cat.es_tecnologia) THEN 'Tecnología' ELSE 'Resto' END AS vertical
    FROM detalle_pedidos d
    JOIN productos  pr  ON pr.producto_id   = d.producto_id
    JOIN categorias cat ON cat.categoria_id = pr.categoria_id
    GROUP BY d.pedido_id
),
pago_principal AS (
    -- El medio "principal" es el de mayor monto dentro del pedido (DISTINCT ON).
    SELECT DISTINCT ON (pedido_id)
           pedido_id, tipo_pago, cuotas, monto
    FROM pagos
    ORDER BY pedido_id, monto DESC, secuencia   -- si dos pagos tienen el mismo monto, gana el primero
),
pago_total AS (
    SELECT pedido_id, SUM(monto) AS monto_total
    FROM pagos
    GROUP BY pedido_id
)
SELECT tp.vertical,
       COUNT(*)                                                                        AS pedidos,
       ROUND(AVG(pt.monto_total), 2)                                                   AS monto_promedio_pagado,
       ROUND(100.0 * SUM(CASE WHEN pp.tipo_pago = 'tarjeta_credito' THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_tarjeta_credito,
       ROUND(100.0 * SUM(CASE WHEN pp.tipo_pago = 'boleto'          THEN 1 ELSE 0 END) / COUNT(*), 1) AS pct_boleto,
       ROUND(AVG(CASE WHEN pp.tipo_pago = 'tarjeta_credito' THEN pp.cuotas END), 2)    AS cuotas_promedio_tarjeta,
       ROUND(100.0 * SUM(CASE WHEN pp.cuotas >= 6 THEN 1 ELSE 0 END) / COUNT(*), 1)    AS pct_en_6_o_mas_cuotas
FROM tipo_pedido tp
JOIN pedidos        p  ON p.pedido_id  = tp.pedido_id
JOIN pago_principal pp ON pp.pedido_id = tp.pedido_id
JOIN pago_total     pt ON pt.pedido_id = tp.pedido_id
WHERE p.estado_pedido NOT IN ('cancelado', 'no_disponible')
GROUP BY tp.vertical
ORDER BY tp.vertical DESC;


/* =============================================================================
   ANEXO A - HAVING: lista de "productos estrella" de Tecnología
   Técnicas: WHERE (filtra filas) vs HAVING (filtra grupos), COUNT, GROUP BY.
   ============================================================================= */
-- Para qué: la recomendación #4 del README pide asegurar el stock de los 144
-- productos que concentran el 37 % de las unidades (P3.b). P3.b solo dice
-- CUÁNTOS son; esta consulta entrega la LISTA concreta para el equipo de compras.
--
-- WHERE vs HAVING, en la misma consulta:
--   * WHERE decide qué FILAS entran al cálculo (antes de agrupar): solo ítems
--     de Tecnología y de pedidos válidos.
--   * HAVING decide qué GRUPOS sobreviven (después de agrupar): solo los
--     productos con más de 20 unidades. Esta condición no puede ir en el WHERE,
--     porque COUNT(*) todavía no existe cuando se evalúa el WHERE.
--   * Poner en HAVING un filtro de filas (como el estado del pedido) también
--     "funcionaría", pero obligaría a agrupar filas que después se descartan.
SELECT LEFT(pr.producto_id, 8) || '...'                 AS producto,
       cat.nombre_en                                    AS categoria,
       COUNT(*)                                         AS unidades_vendidas,
       SUM(d.precio)                                    AS facturacion,
       ROUND(AVG(d.precio), 2)                          AS precio_promedio
FROM detalle_pedidos d
JOIN pedidos    p   ON p.pedido_id      = d.pedido_id
JOIN productos  pr  ON pr.producto_id   = d.producto_id
JOIN categorias cat ON cat.categoria_id = pr.categoria_id
WHERE cat.es_tecnologia                                      -- filtro de filas
  AND p.estado_pedido NOT IN ('cancelado', 'no_disponible')  -- filtro de filas
GROUP BY pr.producto_id, cat.nombre_en
HAVING COUNT(*) > 20                                         -- filtro de grupos
ORDER BY unidades_vendidas DESC, facturacion DESC, pr.producto_id;
-- Resultado esperado: 144 filas, el mismo número que el tramo "Más de 20" de P3.b.


/* =============================================================================
   ANEXO B - EXPLAIN ANALYZE: ¿los índices de estructura.sql se usan de verdad?
   Técnicas: plan de ejecución, Index Scan vs Seq Scan.
   ============================================================================= */
-- Para qué: estructura.sql crea solo 5 índices (trampa #3: no indexar todo).
-- EXPLAIN ANALYZE ejecuta la consulta y muestra CÓMO la resolvió PostgreSQL,
-- con los tiempos reales. Sirve para comprobar que un índice se aprovecha y
-- que una columna sin índice no lo necesita.
--
-- Cómo leer el resultado (columna "QUERY PLAN"):
--   * Index Scan using <índice>: fue directo a las filas usando el índice.
--   * Seq Scan: recorrió la tabla completa, fila por fila.
--   * actual time / rows: tiempo real (ms) y filas que devolvió cada paso.
--   * Rows Removed by Filter: filas leídas y descartadas (trabajo desperdiciado).
--   * Buffers (en PostgreSQL 18 aparece siempre): páginas leídas de memoria
--     (hit) o de disco (read); varían entre corridas según lo que esté en caché.
--   * Execution Time: tiempo total. Los milisegundos varían entre PCs y
--     corridas; lo que importa es el TIPO de recorrido.
-- En pgAdmin también se puede ver gráfico: botón "Explain Analyze" (Shift+F7).

-- B.1 Historial de compras de un cliente (el #1 del Top 5 de P1).
-- Filtra por pedidos.cliente_id, la columna de idx_pedidos_cliente.
-- Esperado: "Index Scan using idx_pedidos_cliente on pedidos" y menos de 1 ms.
-- Sin el índice, PostgreSQL tendría que leer los 99.441 pedidos para
-- encontrar 1; con el índice lee solo ese.
EXPLAIN ANALYZE
SELECT p.pedido_id,
       p.fecha_compra::DATE AS fecha,
       p.estado_pedido,
       d.item_nro,
       d.precio
FROM pedidos p
JOIN detalle_pedidos d ON d.pedido_id = p.pedido_id
WHERE p.cliente_id = '0a0a92112bd4c708ca5fde585afaa872';

-- B.2 Contraste: filtro por una columna SIN índice (fecha de entrega prometida).
-- Esperado: "Seq Scan on pedidos" con ~99.000 "Rows Removed by Filter".
-- Es una decisión consciente, no un descuido: ninguna pregunta del análisis
-- filtra por esta columna, así que un índice ocuparía espacio y haría más
-- lenta cada carga sin acelerar nada que usemos.
EXPLAIN ANALYZE
SELECT COUNT(*) AS pedidos_con_esa_fecha_prometida
FROM pedidos
WHERE fecha_entrega_estimada = DATE '2018-03-15';
